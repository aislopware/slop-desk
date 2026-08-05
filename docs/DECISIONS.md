# DECISIONS — decision log

> One line per decision + status + link to the detailed doc. **When re-scoping: update HERE first**, then fix the related docs (prevents drift). Overview: [00-overview.md](00-overview.md).
> Status: ✅ decided · 🔬 needs a measurement spike · ⏸️ deferred · ❓ open.

## Philosophy
- ✅ **Commit to one good choice per problem.** Renderer = **libghostty** (full surface); structured view = the **read-only inspector**; native Swift owns the wire. No fallback paths to maintain.
- ✅ **Phase 0 — de-risk gate BEFORE building production.** Do NOT park "could kill the architecture" unknowns in a later phase (if they break, all prior-phase work is wasted). Every architecture-defining spike runs in Phase 0; only build once it passes. **Most of Phase 0 has already been measured on M1 Max/macOS 26.5** (harness: [research/spikes/vtbench]). → [18 §0]

## Scope & architecture
- ✅ **Use-case = everyday coding** (running Claude Code), not game-streaming. → [12]
- ✅ **Unified workspace, two co-equal pane transports + a companion:** terminal panes (PTY → TCP → libghostty) and GUI-window panes (ScreenCaptureKit → HEVC → UDP) on one Session→Tab→split workspace; the read-only inspector runs alongside. (Early builds used a free-floating canvas — retired.) → [00], [12], [16], [22]
- ✅ **Terminal was built first** (simpler, sidesteps the input-injection risk layer), but the GUI video path is now shipped and equally first-class — the old "terminal-first / GUI is Phase 4" framing is retired. → [12 roadmap], [00]

## Network / transport
- ✅ **Assume a trusted WireGuard mesh (e.g. NetBird/Tailscale), direct P2P.** Relay = degraded fallback: surface it + warn, do NOT engineer a workaround. → [13]
- ✅ **MEASURED (2 real machines, M1 Max ↔ M2 Pro, over a WireGuard mesh):** RTT **avg 11ms** (8.5–14.5), 0% loss, **direct P2P OVER THE INTERNET** (NAT hole-punch, local 192.168 ↔ remote public IP, not same-LAN). Validates the "5–20ms direct P2P" assumption. → [18 §0]
- ✅ **No app-layer encryption** — the mesh provides WireGuard E2E + deny-by-default per-port ACLs. → [13]
- ✅ **Terminal = plain TCP** (reliable; escape sequences may split across reads → only buffering is needed, no loss-recovery). → [13], [12]
- ✅ **`TCP_NODELAY` mandatory** on every PATH 1 socket right after connect — Nagle coalescing 1-character writes can add +200ms/keystroke (high impact, one setsockopt line). → [17]
- ✅ **Dual data/control channel** (PTY bytes ‖ `TIOCSWINSZ` resize+intent) — burst output doesn't delay the resize-ack (Zellij lesson). → [17]
- ✅ **GUI video = plain UDP** — drop QUIC (TLS is redundant on top of the WireGuard tunnel). → [03], [13]
- ✅ **Do NOT pin `requiredInterfaceType`** (a userspace-WG interface shows up as `.other` → pinning would break it). → [13]
- ✅ **serviceClass/DSCP has no effect through the tunnel** (WireGuard zeroes DSCP) → app-layer adaptive rate. → [13]
- ✅ **Discovery:** mDNS/Bonjour is same-LAN only (does not traverse the mesh) → connect by mesh DNS/IP. → [13]
- ✅ **A lightweight control plane is still needed** despite P2P (push notification + offline-queue): mesh management + APNs/FCM directly. → [13 §5b], [15]

## Terminal renderer (client)
- ✅ **libghostty full surface** (not vt + own renderer). → [12]
- ✅ **Own a minimal external-backend patch ourselves** (ref `daiimus/ghostty` External.zig; Lakr233 InMemorySession + build.yml as reference), build the XCFramework via Zig, pin the upstream SHA. Do NOT depend on the wiedymi fork (the weakest one). → [12]
- ✅ **Renderer = libghostty** (full surface). SwiftTerm is referenced only as a *citation* for the POSIX PTY pattern (forkpty/DispatchIO) in [12] Part B — not a dependency. → [12]
- ✅ **Route every key through `ghostty_surface_key`** (Ghostty encodes kitty/DECCKM itself); do NOT use the Lakr233 bypass path. → [12]
- ✅ **Do NOT build a full Mosh shadow-framebuffer predictor (v1).** Opaque ghostty → would force a duplicate VT parser (desync risk); the Claude Code TUI uses alt-screen → the predictor is OFF there; the benefit exists only at the shell prompt, and at the mesh's low RTT Mosh itself withholds prediction. **Glitch-window caret (cursor column)** = cheap Phase 2 option. → [17]
- ✅ **External-IO exists only in forks** (verified: NOT in upstream): `wiedymi/ghostty:custom-io` (VVTerm ships it) + `daiimus/ghostty:ios-external-backend` (Geistty ships it, has External.zig+resize+tests). The pattern is battle-tested. → [17]
- ✅ **2026-07-11 — libghostty delta SLIMMED to external-IO-only** (12.5k → 2k patch lines). The daiimus fork's tmux control-mode viewer + iOS sync-search + `selection_bounds` C APIs were DROPPED (zero Swift references — SlopDesk *is* the *mux replacement*); dropping tmux restored upstream's DCS/ST parser (`dcs.zig`/`parse_table.zig`) and removed a per-keystroke mutex round-trip in `queueWrite`, which also retired local patch 0002 (`queueWriteLocked` — its recursive-lock trigger left with the tmux wrapping). Ex-patch 0001 (sync `updateFrame` in `draw()`) was folded into the consolidated delta and RACE-FIXED with a new `update_mutex` in `generic.zig` serializing every `updateFrame` entry (audit found main-thread `draw()` racing the renderer thread's `updateFrame` on unlocked renderer state). Kept: External.zig + embedded glue + `draw_now` + config `load_string`/`load_file_len` + Metal teardown-UAF fix + Unicode-17 width tables + a Termio `size`-under-lock torn-read fix. → [`ThirdParty/ghostty/README.md` "Pins + the SLIM delta"]
- ✅ **Threading (C) = SOLVED:** feed_data/refresh/draw **main thread only**; TCP-rx bg thread → `await MainActor.run`; CVDisplayLink cb → `DispatchQueue.main.async`. Avoid actor-suspension escapes. → [18 C]
- ✅ **Echo-latency PATH 1 = MEASURED** (2 machines, WireGuard-mesh P2P): round-trip p50 **9.2ms** / p99 17.8ms → feels-local, **predictor NOT needed** (confirms dropping Mosh). → [18 §0]
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

## Codec (GUI video path)
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
- ✅ **Loss recovery = LTR-refresh + Reed–Solomon FEC with adaptive tiering** (`FECScheme` + `AdaptiveFECPolicy`) instead of forced-IDR (needs a client→host ACK, fallback IDR 2-RTT); 4B seq-number/packet. FEC is RS over GF(2⁸) (NEON-accelerated in `CSlopDeskSIMD`): `m=1` is byte-identical to the original XOR parity, `m≥2` recovers multi-packet loss. → [17], [03]
- ✅ **Adaptive parity-`m`** (2026-06-18): the FEC parity count steps per-frame by measured loss (clean → m=2 lower overhead, burst → m=5 strong recovery) via the existing 3-bit wire FEC-tier field — **no wire-format change**, fast-attack on loss / slow-decay when clean. `SLOPDESK_ADAPTIVE_FEC_M`, deploy-together. → [03]
- ✅ **RE-SCOPE: selective retransmit (NACK / ARQ) for video is now allowed** (2026-06-18) — supersedes the old "never retransmit video (1 RTT → stutter)" rule, whose premise (naive replay-and-stall) breaks once a **playout buffer ≫ RTT**: a NACK'd fragment retransmit lands *inside* the buffer → fills the hole before playout, **no stutter** (WebRTC model). FEC stays first; a FEC-unrecoverable frame is HELD a small grace, the client NACKs the missing fragments (wire recovery type 6), the host re-sends them from a bounded ring (cheaper than a recovery-IDR; recovers whole-frame losses FEC cannot). LTR-refresh/IDR is the fallback once the grace expires. `SLOPDESK_NACK`, default OFF, deploy-together. → [03 §FEC vs retransmit], [10 §LAN policy]
- ✅ **Client frame pacing = `CADisplayLink`/VSync** (NOT decode-completion); show-last-frame when the queue is empty; `CVMetalTextureCache` zero-copy; `CAMetalLayer.maximumDrawableCount=2`. → [17]
- ✅ **Separate window-geometry channel** (move/resize/title) → the client repositions its `NSWindow` before the next video frame. → [17]
- ✅ **1 `VTCompressionSession`/window**, gate `RequireHardwareAcceleratedVideoEncoder=true`. 📏 **MEASURED on 2 machines: ~6 windows 1080p@30fps / encode-engine** (M2 Pro 1 engine→~6 @184fps; M1 Max 2 engines→~8–10 @340fps; 32-session ceiling). The research claim "2–4" is WRONG. The client only decodes → encode only constrains the host role. 1–3 windows = non-issue. Query `UsingHardware` once at creation (polling = crashes mediaserverd; -12900 under low-latency); recreate on resize; retry -12905. → [18 G]
- ✅ **Coordinate mapping (B) = SOLVED**: `kCGWindowBounds`→normalize→`postToPid` (needs the TCC "Post Event" permission); fix multi-monitor by flipping to Cocoa-space before `NSScreen.intersection`; window-move = AX `kAXWindowMovedNotification` (END) + poll `CGWindowListCopyWindowInfo` (drag). Tag `eventSourceUserData` to filter self-injection. → [18 B], [05]
- ✅ **macOS 26 multi-NALU — MEASURED = 1 NALU/CMSampleBuffer** (downgraded from watch-item; still iterate NALUs defensively). → [18]
- ✅ **F decode latency — MEASURED p99 1.1ms** (synchronous, NOT 2-frame-buffered). → [18 F]
- ✅ **D cursor-strip = MEASURED PASS** (client M2 Pro): `showsCursor=false` cleanly strips the cursor from per-window capture (diff 120px = the cursor; present with true / absent with false). → [18 D]
- ✅ **Phase 0 has no gating spikes left** — every architecture-defining risk measured PASS on 2 real machines. What remains are implementation-level spikes only (alt-screen e2e, iOS A-series re-confirm). → [18 §0]

## FPS / latency

> **RE-SCOPE 2026-06-16 — latency-first coding reframe.** SlopDesk is a coding tool, NOT a game/video stream. After a long push chasing Parsec-class motion smoothness, the priorities are reset, in strict order: **(P1) zero input latency** (keyboard + mouse, incl. the visual echo), **(P2) sharp-when-stable** (transient blur during scroll/motion is fine; the instant motion stops, text must re-sharpen fast), **(P3) fps 23–30 is enough** (may drop lower on bursts). Motion smoothness and heavy loss-recovery of transient frames are now low priority and may be simplified. The bullets below supersede the earlier "smoothness-first" decisions.

- ✅ **GUI video-path defaults to 30 fps with idle-skip** (`--fps` knob; 60 still reachable). Reverted toward the original ~24–30 target: 30 fps halves the per-frame byte budget at the same ceiling → crisper individual frames + less self-induced congestion/loss, and transient scroll blur is acceptable. Capture stays at 2× the encode fps (~60 Hz) so a typed-character change is still picked up within ~16 ms, not quantized to the 33 ms encode slot. Idle-skip keeps a static screen near-zero. → [12], [09]
- ✅ **Client presentation defaults to PRESENT-ON-ARRIVAL** (jitter depth 1, no playout hold). The deadline pacer + adaptive playout buffer (HW-validated for Parsec-style smoothness: present-gaps 0.37%→0%, max-hold 258→91 ms) add a standing buffer to the keypress→echo loop, and P1 input latency now outranks smoothness. The adaptive 1↔2 depth boost (`pacer_depth_policy`) is also default-off (depth pinned at 1). `SLOPDESK_PACER=deadline` (+ `SLOPDESK_ADAPTIVE_DEPTH=1`) restores the smoothness-tuned pacer for a jittery-WAN A/B. → [17], [11]
- ✅ **Sharp-on-stable: crisp re-anchor ~300 ms after motion stops** (`StaticIDRDecider`, quiet window 1.0 s→300 ms, poll tick 0.25 s→80 ms; `SLOPDESK_QUIET_MS` / `SLOPDESK_IDR_TICK_MS`). The in-motion path stays cheap/blurry (pure-VBR + QP ceiling); the QP18 crisp IDR rides the same session (no client decoder rebuild). → [17]
- ✅ **HiDPI 2× virtual-display capture is default-ON** (`--no-virtual-display` / `SLOPDESK_VD=0` to disable) — the single biggest text-sharpness lever; a 1× fallback now logs a loud warning rather than silently shipping soft text. → [12]
- ✅ **Terminal-path latency = network RTT** (~1–5ms LAN-direct), no vsync/encode/decode. → [13]
- ✅ **The floor-analysis [11] applies to the GUI video path only.** Chasing motion-to-photon <16ms / 120fps / ProMotion / beam-racing is over-engineering for coding and stays out of scope; the goal is **zero felt input latency + crisp-on-stable at ~30 fps**, not motion smoothness or a hard latency floor. → [11], [12]

## Distribution
- ✅ **Host non-sandboxed** (spawns a shell + CGEvent for the GUI path) → Developer-ID + notarize, **outside the Mac App Store**. The client viewer can go on MAS. → [06], [12]

## Input injection (GUI video path)
- ✅ **Activate-then-control, ONE window at a time (must be focused).** No need to inject into background windows (which also sidesteps the R1/R2 cooperative-activation issues on macOS 14). Raise + focus the target window, then post CGEvents; tag `eventSourceUserData` to filter self-injection. → [05], [17]
- ✅ Applies to the GUI video path only; the terminal path avoids this entirely (input = bytes → PTY stdin). → [05]
- 🔬 Remaining = **coordinate mapping** client video-region → host window/screen (Retina + y-flip + window-move). → [17 §3.9]

## Security / auth
- ✅ **NO app-layer auth — plain.** Personal use only, inside a trusted WireGuard mesh (e.g. NetBird/Tailscale) → the boundary = mesh membership + deny-by-default per-port ACLs, not the app. Drop pairing/token to cut latency. **Accepted residual risk:** the PTY accepting bytes = RCE bounded by mesh membership; a compromised peer exposes the host — accepted for personal use. → [13]

## Single language: Swift + native SIMD kernels  *(was: Rust core / FFI boundary)*
- ✅ **REVERSAL (2026-06-19): one language = Swift. The Rust core (`slopdesk-core`) + the FFI boundary (`slopdesk-ffi`, cbindgen, generated header) are being removed; every codec/FEC/controller/terminal-protocol module is reabsorbed into optimized native Swift.** Rationale: the two-language cost was the **boundary, not the languages** — ~21K LOC of FFI machinery (ffi crate ~15.9K + generated header ~5.2K) bridged to only ~700 LOC that genuinely needs native SIMD. FFI is a *measured tax* (bulk per-pixel codecs are 5–7× slower over it, so they were already kept native Swift); controller/codec logic lowers through LLVM identically in either language, so it is perf-neutral. Collapsing to Swift **removes the marshalling tax** (per-frame boundary crossings get *faster*) and **shrinks total `unsafe`** (the tree's only `unsafe` was the deleted ffi crate). → reverses the three SUPERSEDED entries below.
- ✅ **The ~700 LOC of genuine SIMD — RS GF(2⁸) region-multiply + frame-hash, NEON split-table `vqtbl1q_u8` — stays as native code in a tiny C SwiftPM target Swift links directly** (bridging header, **no cbindgen / no marshalling** — C-interop is free, unlike the Rust-FFI ABI tax). Same `tbl.16b` codegen as the Rust NEON ⇒ perf-identical. Pure-Swift `SIMD16<UInt8>` is **rejected for GF-multiply** (no `vqtbl` table-lookup exposed → slower). This C target becomes the **only** remaining `unsafe`; allowlist it and SwiftLint-ban `Unsafe*` elsewhere to approximate the lost compiler-proven `#![forbid(unsafe_code)]` with a CI-enforced convention.
- ✅ **`golden_vectors.json` becomes a single-impl Swift regression pin** (was cross-language Swift↔Rust `golden_parity`). It was generated FROM the original Swift codecs and the Rust port is bit-identical, so each module reabsorbs to Swift pinned by the **same** vectors. Bit-exactness rules are unchanged and load-bearing: float math stays **separate `mul`+`add`, never fma**; wire stays **manual big-endian binary** (no JSON/Codable on the hot path); decoders **validate-then-drop** corrupt UDP (return optional/throw, never force-unwrap untrusted input); C-struct bools are `u8` read `!= 0`.
- ✅ **Migration shape = resurrect + fresh-translate.** Modules that were Swift **before the port** (commit `44acead`, "Swift→Rust live swap") are recovered from git as the trusted bit-exact reference, then any post-port wire/logic deltas re-applied. Modules added **directly to Rust after** the port (Reed–Solomon FEC — the original Swift was XOR-only; `scroll_reprojection`; `live_congestion_controller`; NACK/ARQ; newer recovery policies) are translated Rust→Swift from scratch. **Teardown of the ffi crate + cbindgen + drift-gate + the rust-before-swift build ordering happens LAST**, only after every module is reabsorbed and green. → [CLAUDE.md conv. 1–7 to be rewritten on completion]
- ⤵️ **SUPERSEDED (2026-06-19)** ~~Rust core is the source of truth; agreement is *proven*, not assumed. Every wire codec/FEC/controller lives in `slopdesk-core` (`#![forbid(unsafe_code)]`, zero-dep); Swift delegates and the `golden_parity` test pins byte-equality. The `slopdesk-ffi` C-ABI is the only crate with `unsafe`, all raw-pointer primitives isolated to `src/raw.rs`.~~ Kept for history; the `forbid(unsafe_code)` *compiler proof* is the one real guarantee lost (now CI-enforced convention instead).
- ⤵️ **SUPERSEDED (2026-06-19)** ~~The C header `include/slopdesk_ffi.h` is GENERATED by cbindgen from the Rust surface, with a CI drift-gate that regenerates and `cmp`s.~~ The header, cbindgen (0.29.4), and the drift-gate are all removed with the ffi crate.
- ⤵️ **SUPERSEDED (2026-06-19)** ~~The "cbindgen reorders `#[repr(C)]` fields" objection was empirically REFUTED; `tests/smoke.c` + `tests/ffi_boundary.rs` stay as the runtime ABI proof.~~ Moot once there is no C-ABI; the C *kernel* target keeps a focused `tests/` for its pointer+length contract instead.

## Coding-workspace redesign (2026-06-20) — binding; plan in [42](42-implementation-plan.md), research in [41](41-redesign-research.md)
- ✅ **Retire the infinite canvas → `Session → Tab → Pane` n-ary tiled split tree.** The free-floating `Canvas` (drag/snap/non-overlap/camera) is the wrong primitive for a coding tool; every competitor (tmux/Zellij/WezTerm/Muxy/Herdr/Warp) converged on a recursive split tree under named sessions/tabs because it is keyboard-drivable, deterministic, and trivially serializable. Arity = **n-ary** (Zellij `TiledPaneLayout`): closing child N redistributes flex equally among siblings instead of WezTerm's "sibling eats all freed space". The split tree stores only `PaneID`s; `PaneSpec` lives in a `Session.specs` side table so a rename never churns a tree diff. **`WorkspaceStore`'s intent-tree → `reconcile()` → registry pattern is preserved verbatim** — only the leaf-id *source* moves (`canvas.allIDs()` → `workspace.allPaneIDs()`); the invariant `Set(registry.keys) == Set(allPaneIDs())` is unchanged. Zoom is out-of-tree render-only state (`Tab.zoomedPane`); siblings stay mounted at `opacity 0` to avoid a libghostty surface rebuild. → [41 §3.1], [42]
- ✅ **Coding-IDE chrome (Muxy-inspired), retire the generic `NavigationSplitView` look.** Hidden title bar (traffic lights float over a full-height sidebar), a **sessions sidebar grouped by host** with a rollup agent-status dot (Herdr: blocked > working > done > idle), a **tab bar** per session, and a recursive split-pane detail (`SplitTreeView`) replacing `CanvasView`. `PaneLeafView`'s kind switch is reused unchanged (layout-agnostic); `FloatingPaneHandle`/`CanvasView`/canvas solvers are deleted. The generic chrome blocked the product from reading as a coding tool and the canvas affordances (pill, snap, grid) have no place in a tiled layout. → [41 §3.4], [42]
- ✅ **Claude Code = runtime auto-detection, not a stored `PaneKind`; remove the dedicated pane.** Drop `PaneKind.claudeCode`; any `.terminal` pane running `claude` is detected and surfaces status. Defense-in-depth, three signals: **(1) host foreground-process watch** (`tcgetpgrp(masterFD)` → process name; primary, zero-config; wire type 26), **(2) Claude Code hooks** (installer writes `~/.claude/hooks/*` + patches `settings.json`, posts to a host-local AF_UNIX socket; richest state; wire type 27 — reuse the existing `SlopDeskInspector.HookParser`, extended with `Notification(permission_prompt)`/`Stop`/`SessionEnd`), **(3) client screen-manifest fallback** (no wire). The status state machine + manifest matcher live in a new isolated `SlopDeskAgentDetect` SwiftPM target that physically cannot import GUI/VT. Forcing the user to pre-declare a Claude pane is worse UX than detecting a running `claude`; Muxy/Herdr/Warp all detect. `HostServer.LaunchMode` defaults to plain shell (retire the `--claude` daemon mode → a launch preset). → [41 §4], [42]
- ✅ **Full GUI Settings bridging a settings model to the `SLOPDESK_*` env sites.** Two mechanisms: **`@AppStorage`** (live, client/terminal-render prefs) and a **prefs sidecar → daemon-at-launch** for the ~80 video flags that are read at `static let` init from `ProcessInfo.environment` and cannot live-reload (marked "applies on reconnect/restart"). The ~80 sites route through a new `EnvConfig` resolver (`overrides[k] ?? ProcessInfo.environment[k]`), proven **behavior-preserving** (empty overrides ≡ today, pinned by test + `make golden` + loopback-validate). Panels: General · Appearance · Terminal · Video & Network · Agents · Notifications · Keyboard Shortcuts · Connections · Advanced/JSON. Env-only config blocked non-developers and made the product undemoable. → [41 §5], [42]
- ✅ **Terminal feature parity with Ghostty/Warp/Muxy.** Font/theme/keybind config via `ghostty_config_load_string` (before `ghostty_config_finalize`, then read cell size + send a PTY resize before first keystroke — unblocks the documented grid-mismatch), in-surface splits/tabs via our tree, scrollback search (⌘F via `ghostty_surface_binding_action` or client ring-search), a sticky command header (reuses OSC 133 / `commandStatus` type 23), OSC 8 hyperlink click-to-open (sniffer `case "8"` + additive wire type 28), launch presets (repurposed `LayoutPreset` → Session/Tab template), and a right-click context menu. All wire additions are **golden-additive** to `terminalWireMessages` (surgical merge, never `>`-redirect; the key IS golden-pinned, generator `slopdesk-corevectors/main.swift:664`) within wire version 1; old clients drop unknown CONTROL types. → [41 §6], [42]
- ✅ **Migration = a real v9→v10 step (first non-trivial one).** A v10 `Workspace` has no `canvas`/`groups`, so a v9 file fails the *typed* v10 decode before migration runs → load() gets a **pre-decode raw-JSON version peek** + a **frozen `WorkspaceV9` mirror** (immunized against future live-type edits) → `WorkspaceMigrationV9toV10` wraps `canvas.items` into one Session, maps `groups` → tabs, and preserves every `PaneID`+`PaneSpec`. The single-user no-compat policy technically allows a blank reset, but the first real migration is cheap and preserves user layouts; unknown/future versions still reset-to-default with a `.corrupt` sidecar. → [41 §3.6, §7.4], [42]
- ⏸️ **Schema-reserved but deferred:** per-session multi-host (`Session.connection` modeled now; MVP shares the one `AppConnection` to bound blast radius) and `Tab.floatingPanes` (empty in MVP, so no later migration). → [41 §7.2, §7.3], [42]
- ✅ **W5 cutover (2026-06-20): the `TreeWorkspace` is now the LIVE source of truth; the canvas `Workspace` is retained-but-dead.** `WorkspaceStore` gained a `liveModel` switch — the app constructs with `.tree` (init reconciles the tree, a debounced/immediate save persists the v10 tree via `WorkspacePersistence.loadTree()`/`save(_:TreeWorkspace)`, the new `SplitWorkspaceView` shell binds it), while every existing test keeps the default `.canvas`. The canvas code (`Canvas*`/`CanvasView`/`CanvasItemView`/`FloatingPaneHandle`/`Workspace`/`reconcile()`) is **kept compiling as dead code** behind the cutover (not deleted) so the diff stays reversible and `swift build` green pending the user's eyes-on HW verification of the new shell; the cleanup commit that deletes it is **tracked as a later W5 follow-up**. `WorkspaceTransfer` export/import stays canvas-coupled (v1) — the v2/tree envelope is deferred with the canvas cleanup. → [42 W5]
- ✅ **W5 hardening (2026-06-20): the LIVE features that still routed to the dead canvas under `.tree` are now model-aware.** An adversarial review found busy-pane close (`confirmPendingClose`/`requestClosePane*`/`pendingCloseTitle`), the system-dialog auto-panes (`addSystemDialogPane` + the monitor's close/liveness probes), the chrome close button, ⌘⇧R rename, and the app-launch layout-preset reads all funneled into the canvas `reconcile()` (a guarded no-op under `.tree`) → silently dead on the IDE shell. Each is now split on `liveModel`: tree closes cascade via `closePaneTree`, a system dialog materializes as a transient TAB of the active session, ⌘⇧R renames the active TAB (its `TabBarView` inline field, via `pendingTabRename`), and the launch monitor reads `liveLayoutPresets`. The `.canvas` path stays byte-identical (every canvas test unchanged + green).
- ⏸️ **#8 — no compact/iPhone tree projection (deferred, BLOCKED by pre-existing iOS rot).** The regular `NavigationSplitView` shell (`SplitWorkspaceView`) is the only tree projection; the per-tab iPhone carousel is deliberately NOT built (`WorkspaceRootView` keeps the canvas carousel for compact width on the canvas path). Marked with a `TODO(iOS tree carousel — deferred, see DECISIONS #8)` at `SplitWorkspaceView` so the gap is explicit, not an accident.

## C3 agent-detection hardening (2026-06-20) — adversarial-review follow-up
- ✅ **The HOST is the single source of truth; the CLIENT is a passive display (P1, review #1–#4/#9).** The host ran TWO independent `ClaudeStatusMachine`s (the foreground-watch detector + the hook handler) that BOTH emitted type-27 with no reconciliation (they fought), the client RE-DERIVED presence from type-26 and folded its OWN machine (more conflict + inspector flap), and NOBODY drove `.tick()` so the `.done→.idle` decay never fired (a finished turn stayed 🔵 forever). Fix: ONE `ClaudePaneDetector` per pane/channel owns ONE machine fed by ALL inputs — `.processPresent` (exact-basename via `ClaudeManifestMatcher`), `.hook(event)`, and a per-foreground-poll `.tick(at:)` (~1 Hz, drives the decay) — emitting type-27 ONLY on a `(state,kind,label)` change and type-26 only on a basename edge (a coarse display hint, NOT a second status source). The client now TRUSTS type-27 (`state` byte → `ClaudeStatus(urgency:)`, forward-tolerant), removed its machine + the loose `name.contains("claude")` re-derivation; type-26 updates a display-only `foregroundProcessName` and can NEVER override the status (a transient child taking the PTY can't wipe a `.needsPermission`). The inspector gate is driven off the trusted type-27 status. **No wire ENCODING change** (types 26/27 byte-identical; golden intact).
- ✅ **Block-source provenance (P2, #5).** `ClaudeStatusMachine` distinguished a `blockSource` (`.hook | .manifest | .none`): a manifest `.working`/`.idle` verdict may clear a MANIFEST-set block but stays suppressed under a genuine HOOK block — fixing the stuck-blocked bug where `applyManifest(.needsPermission)` set the same flag that gated the manifest branches (so a manifest block could never clear).
- ✅ **`paneAgentStatus` pruned on pane close (P3, #10/#13)** in the shared `reconcileRegistry` diff core, alongside the sibling `selectedPanes` / `nativeFrameSize` caches — no unbounded growth, no dead-pane status surfacing in a rollup.
- 🔁 **RE-SCOPE (2026-07-29): agent detection has NO flags at all — `SLOPDESK_AGENT_DETECT`, `_AGENT_SCREEN` and the six scrollback-cleanup opt-outs are DELETED with `_AGENT_HOOKS`.** A sweep of all ~250 `SLOPDESK_*` variables (most are tuning knobs, debug seams or runtime handshake, not toggles) asked one question of each boolean gate: is OFF a legitimate mode, or a broken product? Four answered "broken". (1) **`_AGENT_DETECT`** — knowing what the agent in a pane is doing is what this product is for, and the watch is zero-config, host-local and costs a `tcgetpgrp` per second; OFF bought nothing and cost every status the sidebar shows. Its "Foreground-process watch" toggle and the `AgentPreferences.agentDetect` sidecar field go with it, which empties the whole "Agent detection (host)" Settings section. (2) **`_AGENT_SCREEN`** — a second flag AND-ed into the first, with no UI and no operational reason, whose OFF blinded the only detection branch that runs on a host without hooks. (3) **The six `SLOPDESK_SCROLLBACK_STRIP_*` / `_COLLAPSE_*`** — each guards a pass that removes bytes whose only effect on a replay is to be wrong (armed input modes that make the shell read garbage, a TUI's drawing replayed as a pane stuck inside vim, megabytes of progress ticks whose last revision is the only visible one). Six flags for "do not show garbage" is six ways to break a reattach with no way to notice; `ScrollbackReplayTransform.make` now always returns a transform and `_SCROLLBACK_DISTILL` is the one surviving gate. (4) **`SLOPDESK_DETACH_ENABLED`** — OFF made a reconnect spawn a fresh shell instead of reattaching, silently discarding whatever the agent left running; worse, it was AND-ed with `_AGENT_RESUME_ON_RECOVERY`, so ONE behaviour had TWO gates — the exact shape rejected for `_PANE_FANOUT`/`_WORKSPACE_DOC`. "Resume on Recovery" (a real Settings toggle) is now the single gate. **KEPT opt-in, deliberately:** `_AGENT_CONTROL` / `_IPC_ALLOW_SEND_KEYS` / `_IPC_ALLOW_SENSITIVE` (they permit WRITING to a PTY — a real privilege boundary, unlike the read-only hook listener), `_AGENT_PREVENT_SLEEP` (a side effect on the whole machine), `_SHELL_INTEGRATION` / `_OSC133` / `_SHELL_CURSOR` (they modify the user's shell, like installing hooks into their `settings.json`), and the feature toggles whose OFF leaves the product correct but smaller (`_AUDIO`, `_FILE_TRANSFER`, `_GIT_WATCH`, `_SWIPE_NAV`, `_DIALOG_EXPAND`). `agentDetectEnabled:` / `detachEnabled:` survive as INJECTED init arguments — test seams, not user-facing switches. → `HostEnvironment`, `HostServer`, `MuxChannelSession`, `TerminalQueryStripper`, `AgentPreferences`, `SettingsView`
- 🔁 **RE-SCOPE (2026-07-29): the hook listener has NO flag — `SLOPDESK_AGENT_HOOKS` is DELETED, the `AF_UNIX` socket binds unconditionally.** Signal 2 being ranked SECOND is a statement about EVIDENCE (detection works without hooks, via the foreground watch + the screen engine); it was encoded as a default-OFF gate, which is a statement about CONFIGURATION, and the two are not the same. Off, the product is wrong rather than reduced: `ClaudeStatus.done` is producible ONLY on this path (`AgentScreenState` has no `done` verdict — its states are `unknown`/`working`/`blocked`/`idle`), so a finished turn was indistinguishable from one that never happened and the pane went grey; `HookParser.classifyNotification`'s `idle_prompt` filter had nothing to filter; and `ClaudePaneDetector.suppressesChildNotifications` stayed false, so claude's own OSC 9 notification passed through as a second banner. None of that is diagnosable by the person seeing it. Nothing is risked by binding: the listener is READ-ONLY (it parses hook JSON into the detector and never writes to a PTY — that is what `SLOPDESK_AGENT_CONTROL` gates, and why THAT one stays opt-in), the socket is `chmod 0600` in the per-user temp dir, and an installed hook with no socket to reach already exits silently. The `AgentPreferences.agentHooks` sidecar field + its Settings toggle are removed with it (an older sidecar naming the key still decodes — an unknown key is simply not read). What stays a user CHOICE is INSTALLING the hooks into their own `~/.claude/settings.json` — that writes a file slopdesk does not own, so it remains the explicit Settings → Agents action. `AgentHooksController.installedInactive` survives and now means the bind FAILED (or the host is an older build), never a configuration choice. → `HostEnvironment`, `slopdesk-hostd/main.swift`, `AgentHookListener`, `AgentPreferences`, `EnvBridge`
- ✅ **Dead W11 launch code removed (P4, #12).** `ClaudeCodeProfile.environment()`/`loginShellArguments()`/`forcedKeys`/`inheritedKeys`/`command` + `ClaudeAuthResolver`/`AuthStrategy` were unreachable after the curated-launch retirement (only `ClaudeCodeProfile.Term` is still used, by `TerminfoResolver`/`HostServer`/`HostEnvironment.defaultTerm`); removed + their `EnvAndAuthTests` deleted.
- ⏸️ **Manifest fallback: available but NOT yet live-fed (P6, #8 — documented deferral).** The no-hooks `ClaudeManifestMatcher` verdict folds through `ClaudePaneDetector.manifestVerdict(_:at:)` (wired + unit-tested into the ONE machine), but the live host does NOT drive it: the host streams raw PTY bytes + keeps only a tiny OSC sniffer (no screen buffer), so `coarseStatus(screen:)` would need a recent-output ring scanned per chunk on the latency-critical read-loop thread (not cheap/clean — taxes input-to-photon), and the cheap title-only signal yields just PRESENCE, which the foreground watch already supplies with a strictly-better EXACT-basename match. P1 is correct without it (presence + hooks detect a `claude`). When a cheap host-side screen-text source lands (e.g. a host libghostty surface), drive the seam from `MuxChannelSession`.

## W14 terminal parity backlog (2026-06-20) — plan in [42 W14](42-implementation-plan.md)
- ✅ **⌘F find-in-terminal — client-side over the scrollback mirror, PLUS libghostty's own in-surface search.** The pure `TerminalSearchController` (literal/regex, case toggle, ordered match list, wrap nav, "N of M") is unit-tested against an in-memory buffer and drives the `TerminalFindBar` overlay; it reads the surface's `scrollbackTextLines()` (`ghostty_surface_read_text` over a `GHOSTTY_POINT_SCREEN` span) as the text source. The bar ALSO fires libghostty's `start_search:<needle>`/`navigate_search` binding actions so the surface highlights/scrolls to matches. **API gap (documented):** libghostty exposes the search RESULT via the `GHOSTTY_ACTION_START_SEARCH/SEARCH_TOTAL/SEARCH_SELECTED` C `action_cb`, which SlopDesk's embedding does not yet plumb a surface→view route for — so the count/index UX is computed client-side over the line mirror (exact for the line-oriented mirror). Routing the surface's search-result callbacks back into the find bar is a future enhancement, not a blocker. ⌘F is a new binding in the W6 `WorkspaceBindingRegistry`.
- ✅ **OSC 8 hyperlink click-to-open — rely on libghostty, NO wire type 28.** libghostty owns OSC 8 hit-testing + the click internally and asks the embedder to open the resolved URL via `GHOSTTY_ACTION_OPEN_URL` (with `GHOSTTY_ACTION_MOUSE_OVER_LINK` for the hover affordance). The embedding's `action_cb` (previously a no-op stub) now handles `OPEN_URL` → `NSWorkspace/UIApplication.open`. So the **document-deferred host-side path** (extend `HostOutputSniffer` with `case "8"` + a new wire type 28) is NOT built — it would duplicate what libghostty already does and add a wire surface for no gain. Wire type 28 stays free; golden is byte-identical (confirmed: no `terminalWireMessages` change).
- ✅ **Right-click context menu — pure enablement model + compile-only `NSMenu`.** `TerminalContextMenu` (item list + per-item enablement: copy needs a selection, paste needs clipboard text, the rest always-on) is unit-tested headlessly; `GhosttyLayerBackedView.menu(for:)` renders it and routes copy/paste/select-all/clear to libghostty binding actions, paste-as-keystrokes to `text(_:)`, and split/find to the store via the `TerminalViewModel` callbacks.
- ✅ **Launch presets / launch configurations (Warp parity) — pure model + store apply.** `LaunchPreset` (title + command + optional cwd + optional 2-pane split) persists on `TreeWorkspace.launchPresets` (additive-tolerant decode: a pre-W14 v10 file with no key re-seeds the built-ins; never bricks load); `LaunchPresetEngine.plan(for:)` (unit-tested) expands one to pane spec(s) + the `cd`/command keystrokes; `WorkspaceStore.applyLaunchPreset` opens a new tab, splits if needed, materializes the panes, and types the command after the PTY connects. Built-ins: **Claude Code** (`claude`), **htop**, **Git log**. The retired curated-`ClaudeCodeProfile` daemon mode (per the redesign) is replaced by this Claude-Code preset.
- ⏸️/✅ **Sticky command header / jump-to-prompt (OSC 133) — libghostty `jump_to_prompt` lever surfaced, sticky header DEFERRED.** libghostty owns OSC 133 prompt marks and `jump_to_prompt:<delta>` as a binding action; `GhosttyLayerBackedView.jumpToPrevious/NextPrompt` surface it (compile-only responder selectors) through the same `performBindingAction` lever, ready for a menu/chord binding — no host/wire change (the host's OSC 133 `commandStatus` type 23 is unchanged). A persistent **sticky command header** pinned atop the screen is **document-deferred**: it needs the parsed grid/scroll-offset (libghostty owns it, not exposed cheaply through the C API) to know when output has overflowed the producing command — not worth a fragile client-side reconstruction now.

## Agent supervision + workspace UX (2026-06-21) — branch `feat/coding-workspace-redesign`
- ✅ **Agent-supervision control surface = state + a push events stream + self-report, no polling (host/`slopdesk-ctl`).** The agent-drive control socket becomes a real supervision API so an orchestrator (and the GUI) can answer "which pane needs me?": `list-panes` carries each pane's agent `state` (idle/working/blocked/done) read from the single per-pane `ClaudePaneDetector` the foreground poll already drives; a top-level (no-paneId) `subscribe` fans `{type:agent_status_changed,paneId,state,title,ts}` NDJSON across ALL panes on every transition (coarse-state dedupe — a same-state re-report does not re-emit), reusing the existing `SubscribeState`/`NSCondition` machinery; a `report_agent` verb lets a pane self-declare `{state, message?}` folded into its detector at authoritative precedence, **sticky for a 30 s grace** so a non-`claude` agent's self-report survives the ~1 Hz foreground-absence poll while a truly-exited agent still decays. `read --unwrapped` returns logical lines (join chunks → ANSI-strip → split on hard `\n`) robust to read-chunk boundaries, keeping the unterminated trailing prompt (the awaiting-input cue). A **spawned pane carries env sentinels** (`SLOPDESK_CTL=1`, `SLOPDESK_CTL_BIN`, `SLOPDESK_CONTROL_SOCKET`, plus the existing `SLOPDESK_PANE_ID`) so an agent inside a pane self-orients with zero discovery. Hardening: the events subscriber spawns a disconnect-reader that reaps the idle observer+fd+thread instead of parking forever (closes a trusted-mesh fd/thread-exhaustion hole).
- ✅ **ctl surface parity pass (herdr-class agent drive): block-truth verbs over the EXISTING OSC-133 segmentation — no new parser, no wire change.** The pane-control gaps vs tmux/zellij/herdr (no exit code, no block-level read, no run-and-collect, no named keys, regex-only wait) all close by surfacing what the host already tracks. `list-panes` grows `cwd` (the type-33/34 `lastCwdTruth` latch), `command` (live `PTYForegroundProbe` basename), `rows`/`cols` (`TIOCGWINSZ`), `lastExitCode` (a new sniff-point latch of `.commandStatus(.idle(exitCode:))` — works even with blocks off), and `stateMessage` (the detector label — a blocked pane's QUESTION rides `list-panes`); unknown optionals are OMITTED, never fabricated. **`last-output`** (read-only verb) serves the last N closed blocks (command text + output + exit + duration) straight from the `CommandBlockTracker` ring, plus the still-running block's metadata. **`run --wait`** is the herdr-style collect primitive: snapshot `expectedNextCommandIndex` BEFORE the write, block on a new per-session BLOCK observer (fired in `feedBlocks` AFTER the ring retains output, so the body is always fetchable), answer `{exitCode, durationMs, output, blockIndex}`; the CLI prints the output and EXITS WITH THE COMMAND's code (ssh-style; timeout → 124). **`write --key`** takes the tmux `send-keys` vocabulary via the pure `ControlKeyMap` (C-x fold, M-x meta, CSI arrows/nav, SS3 F1–F4; unknown token rejects the WHOLE request). **`wait --state idle,done,blocked`** rides the existing `agent_status_changed` fan-out (register-then-recheck so a registration-gap transition is never lost). Two enablers: control-spawned panes now layer the SAME `ShellIntegration` shim as mux panes (no shim → no 133 marks → block verbs dead) and follow the server's `blocksEnabled` (the old `false — no client` rationale predated the ctl socket being a consumer); block output gets the PROMPT_SP cluster excised by re-appending a synthetic `133;D` anchor and reusing `PromptEOLMarkStripper` (honest: the real `D` did abut those bytes). Read-only-by-default posture unchanged: `last-output` joins the ungated read set; `run --wait` stays behind `SLOPDESK_IPC_ALLOW_SEND_KEYS`. HW-verified end-to-end (spawn → run --wait exit-propagation → C-c interrupt closing a block at exit 130 → state-wait → fail-closed refusal).
- ✅ **`screen` verb = rendered-screen dump via an on-demand host-side VT emulator, NOT a persistent grid.** The last parity gap vs zellij's `dump-screen`: `read` returns raw scrollback bytes, so a TUI pane (vim/htop/claude) is unreadable to an agent. Closed by `TerminalScreenModel` — a pure VT100/xterm text-placement emulator (cursor/erase/scroll-region/ICH-DCH-IL-DL/DECSTBM/DECOM/DECAWM deferred wrap/alt-screen 47-1047-1049/DEC graphics charset/UTF-8 wide+combining width; SGR parsed and discarded; unknown sequences consumed, never trapped) fed the scrollback ring's RAW bytes (`scrollbackRawForControl`, newest-whole-messages cap 8 MiB) at the pane's live `TIOCGWINSZ` size. **On demand, not resident:** zero hot-path cost, no per-pane grid state to keep coherent — and starting mid-ring is safe because full-screen apps repaint (the same property the ring's own truncation already relies on). The host stays renderer-free as a steady state; the model exists only for the duration of one verb call. Read-only verb (ungated, like `read`); response carries the grid `lines`, trailing-blank-trimmed `text`, 0-based cursor, and the `altScreen` flag. `--rows/--cols` override for agents that want a specific reflow (clamped 512×1024).
- ✅ **Supervision cockpit (client) = surface the agent's OWN blocked state, route the human answer — NO app-layer approval gate.** The per-pane type-26/27 status drives an "effortless which-agent-needs-me loop" for a human supervising many parallel agents: a blocked pane gets a red **attention ring**, a done pane a green one, drawn **concentrically with the P2 blue focus ring** (a focused+blocked pane shows both — red outer attention, blue inner focus) and shown even when the pane is NOT focused (the whole point — notice a background pane); calm breathe, never dims a pane. A tab whose rollup is blocked/done gets a status wash + bottom glow + unread dot; an OS `UNUserNotification` fires only on a needsPermission/done EDGE (coalesced, click reveals the pane); **jump-to-unread (⌘⇧U)** focuses the oldest pane needing attention (needsPermission before done, switching tab/session); the sidebar caption shows the agent's actual blocking question (the host type-27 label) + a liveness glyph. **The app does NOT add an approval/permission gate of its own** — it only renders the agent's self-reported `needsPermission` and lets the human type the answer into the pane; the security boundary stays the trusted WireGuard mesh (no app-layer auth — DECISIONS §Security), not a new client-side prompt arbiter.
- ✅ **Premium dark-IDE UI = a disciplined application pass over the existing `SlopDeskTheme` tokens, NOT a theme rewrite.** The UI read flat because the (already-sound) tokens were applied without elevation or a focus ring. Rules made binding: a **3-step elevation ladder** (sidebar bgRaised > pane card bg > gutter bgSunken) so panes read as raised cards; the focus ring is `isFocused && window-key ? accent@1.5pt : hairline@1pt` on the same continuous card and **never dims the inactive pane** (the documented no-dim invariant); **glass (`glassedSurface`, macOS 26 glass else ultraThinMaterial) is allowed on transient overlays ONLY** (the ⌘K command palette) — never on a content/terminal pane (the one-surface rule); semantic status accents (blue/green/red/yellow + soft fills) drive the agent dots and the connection/RTT readouts, the working dot is a smooth interpolated breathe (not a TimelineView strobe), and dot sizes route through `UIMetrics` so the UIScale density presets hold.
- ✅ **Sync-input to all panes (⌘⇧I, zellij `ToggleActiveSyncTab`).** Per-tab arming (`Set<TabID>`) fans every keystroke in the active tab to all its sibling panes via the focused pane's `broadcastTap` → sibling `sendBytes`, reentrancy-guarded, surfaced in the tab bar + pane status bar. The chord is sourced from the binding registry and dispatched ONLY via the SwiftUI menu's `.keyboardShortcut` (there is no NSEvent monitor — a binding absent from the menu is a dead chord), so the displayed glyph and the fired chord cannot drift.
- 🔁 **RE-SCOPE (WS-B / B3): there IS now ONE app-level `NSEvent` `.keyDown` local monitor — the live keybinding dispatcher (`WorkspaceKeyDispatcher` + the pure `KeyChordNormalizer`, installed once at launch in `SlopDeskClientApp`).** The "no NSEvent monitor — a menu-absent binding is a dead chord" stance above held only while every workspace chord was a single ⌘/⌥-prefixed shortcut a SwiftUI `.commands` menu could express. The configurable tmux/zellij **multi-key prefix** (default ⌃A then a key) cannot be a `.keyboardShortcut`, and — decisively — a `.commands` menu **cannot swallow a sequence's follow-up key before the terminal first responder** (`GhosttyLayerBackedView`) consumes it into the PTY. So the dispatcher installs one local monitor that runs the pure B2 `PrefixStateMachine` and routes a resolved single chord / completed sequence through `WorkspaceBindingRegistry.route(action:openPaneChooser:)`. **The load-bearing invariant is preserved**: a bare unmodified key is ALWAYS passed through untouched (a table miss returns the event); the monitor swallows ONLY the prefix, armed follow-ups, and bound chords. The override-aware `resolvedChordTable`/`resolvedSequenceTable` keep the displayed glyph and the fired chord in lock-step (no drift). The displayed-glyph guarantee that motivated the old rule is now met by sourcing BOTH the menu and the dispatcher from the same registry. (B5 — delete the legacy hard-coded ⌘D/⌘⇧D branch in `GhosttyTerminalView.keyDown` now that the monitor owns split — is the follow-up; until then the monitor swallows ⌘D first so the dead branch never double-fires.)
- 🔁 **RE-SCOPE (WS-C, 2026-06-25): EVERY new-pane gesture opens the pane-type chooser, and the chooser is a STORE-OWNED model rendered as a CENTERED OVERLAY — not a popover on the hover-hidden `+`.** Two corrections to the overnight WS-C build after HW (cua) testing exposed it never worked for keyboard/menu triggers. (1) **Coverage:** `.newTab` alone gated the chooser; now `.splitRight`/`.splitDown` (⌘D/⌘⇧D), `.spawnFloating`, `.newSession`, the title-`⋯`-menu split, AND the terminal right-click split (`splitFromContextMenu`) all route through `openPaneChooser` — a split MINTS a pane, so it offers Terminal/Remote-window like the `+`. ⌘T (`.newPane(.terminal)`) + ⌘N (`.newPaneDefault`) stay explicit direct-create escape hatches; `nil` opener (tests / iOS / headless) keeps the legacy direct create. (2) **Presentation:** the chooser was a titlebar-local `@State` `PaneChooserModel` presented as a `.popover` anchored to the `+` button and registered via the `+`'s `.onAppear`/`.onDisappear`. That FAILED for programmatic opens — the `+` is `opacity(0)` when the chrome is hidden (a popover on an invisible anchor never renders), two SwiftUI popovers can't coexist (the title-menu popover blocked it), the window often isn't key, and the `onAppear`/`onDisappear` registration **raced a re-render and left `onOpenPaneChooser` nil → the split fell back to a hard-coded terminal** (the "pane creation doesn't ask terminal-or-window" bug). Fix: `WorkspaceStore` OWNS `paneChooser` (a `let`, so it exists from init); the app wires `onOpenPaneChooser → paneChooser.present` ONCE at launch (guaranteed before any keystroke); `ContentColumn` (the always-mounted content root) RENDERS it via `.paneChooserOverlay` (a dimmed-backdrop centred card reusing `PaneChooserMenu`), robust for every trigger and focus state. iOS keeps its toolbar-`+` popover (its own surface). HW-verified: ⌘D → overlay → Terminal splits / Remote-window lands in the in-pane list-first picker.
- 🔁 **RE-SCOPE (WS-C v2, 2026-06-25): the chooser is the new pane's CONTENT, not a modal — create + focus the pane, render the choices INSIDE it.** Supersedes the centred-overlay modal above. Per the user's direction (don't show a popup — create and focus a pane whose content is the choices): a new `PaneKind.chooser` is minted IMMEDIATELY by every new-pane gesture (`WorkspaceBindingRegistry.route` → `WorkspaceStore.openChooserPane(context)`), placed + focused like any pane (`splitPane`/`newTab`/`newSession` already focus the new leaf). `reconcileRegistry` SKIPS a `.chooser` (no live session — `makeSession` is never called for it); `PaneContainer` renders `InPaneChooserView` (Terminal / Remote-window cards, single-key t/r) as the pane content. Picking calls `WorkspaceStore.choosePaneKind(paneID, kind)` which flips the spec kind IN PLACE (same `PaneID`) so reconcile materializes the real session — a `.remoteGUI` pick lands in WS-A's in-pane window picker. **Removed:** `PaneChooserModel`/`PaneChooserOutcome`, `WorkspaceStore.paneChooser`/`onOpenPaneChooser`, the `route(openPaneChooser:)` param + the `WorkspaceKeyDispatcher` opener, `PaneChooserPopover` (overlay) → `InPaneChooserView`; `PaneChooserOption`/`Registry`/`Context` are kept. **Test note:** suites that used `route(.splitRight/.newTab)` to set up REAL panes now translate those verbs to a direct terminal create (route()→chooser is pinned by `PaneChooserRoutingTests`). `make check` green (3294 tests); cua: ⌘D → in-pane chooser → click Terminal → live terminal in place.
- 🔁 **RE-SCOPE (2026-06-25): the default theme is now Monokai Pro (6 filters), panes are FLAT, and the libghostty terminal CELLS follow the chrome theme.** Supersedes the earlier "chrome default is the Paper light theme" decision + the earlier "floating rounded radius-8 CARD" DNA. (1) **Themes:** `SlateTheme` ships the six Monokai Pro filters from monokai.pro/contribute — `monokaiProClassic` (the DEFAULT, dark) + Light / Octagon / Machine / Ristretto / Spectrum — each built by one `monokai(MonokaiSeed)` factory (shared structure opacities, only hues change), keeping legacy `.paper`/`.dark` selectable. `ThemeChoice` gains the six cases (no-backcompat: a stale persisted value decode-fails to the all-nil default = Monokai Classic). Palette cross-verified across 4 ports (iTerm2-Color-Schemes / alacritty-theme / nvim / wezterm). (2) **FLAT pane (the user's "pane bg must match the bg underneath"):** every theme sets `window == content == card == background`, so a pane's surface is the same colour as the backdrop beneath it — no card, no border. The Metal-layer `cornerRadius = 8` in `GhosttyTerminalView` (macOS + iOS sites) is now `0` — the terminal fills its leaf flush/square. (3) **Terminal cells track the theme:** new `SlateTheme.terminalBackgroundHex/terminalForegroundHex` + an `AppearanceApplier.resolveTerminalColors` hook + `TerminalConfigBuilder` bg/fg overrides let `PreferencesStore.applyTerminal` pin the libghostty `background`/`foreground` to the active theme (so a theme switch repaints the terminal CELLS, not just the chrome) — `applyAppearance` re-runs `applyTerminal`. This is the *background-only* path (no named theme / font reflow), so the documented grid-mismatch deferral is untouched. (4) **Repaint fix:** `ThemeStore.apply` now posts the cross-`NSHostingController` notification on theme IDENTITY change (not just `isLight`), so a same-lightness variant switch (Classic → Spectrum) still re-pins + nudges the columns. (5) **Flat divider:** the default `.thin` `NSSplitView` `drawDivider(in:)` draws a PURE-BLACK 1px line (pixel-sampled), a harsh seam on the lighter Monokai chrome — and it's a DRAWN line, not a gap (window/layer bg don't touch it). Since subclassing `NSSplitView` traps `_setupSplitView`, the fix **isa-swizzles** the already-built split view (`object_setClass(splitView, FlatDividerSplitView.self)`, no stored props → ivar-safe) to a subclass whose `drawDivider` fills the divider with the flat theme backdrop so the seam blends. HW-verified (cua): Monokai Classic dark default + flat square live terminal whose cell bg == chrome bg; Monokai Light variant flips chrome AND terminal to the warm off-white. `make check` green (3306 tests, golden zero-diff).
- ✅ **Floating / scratch panes = revive the dead `floatingPanes` seam into real movable+resizable overlay panes (additive v11).** `PaneSpec.floatingFrame` (additive v11, `decodeIfPresent` → an old workspace decodes nil = tiled) marks a float and stores its rect; the render model places floats from `tab.floatingPanes` + the spec frame, clamped into bounds, z-ordered, suppressed on zoom. Pure `WorkspaceTreeOps` own toggle/spawn/move/resize/raise + clamp; the `FloatingPaneView` card keeps **opaque raised terminal content (one-surface rule — glass only on the title strip)** and the **no-teardown invariant** (every leaf stays mounted; a float is just placed by its frame). Float (⌘⇧F) / New Floating (⌃⌘F) chords + Pane-menu items. This makes the schema-reserved-but-deferred `Tab.floatingPanes` (DECISIONS §redesign) live. *(RE-SCOPE 2026-06-29 — see the audit-fix bullet below: Float-toggle → ⌥⌘F, New-Floating → ⌃⌘⇧F, freeing ⌃⌘F for the OS-native Toggle Fullscreen chord.)*
- 🔁 **RE-SCOPE (ui-shell audit, 2026-06-29): ⌃⌘F is RESERVED for the macOS-native "Toggle Fullscreen" (Enter/Exit Full Screen), NOT a workspace binding.** The app had bound ⌃⌘F to `pane.spawnFloating` ("New Floating Pane"), and the app-level NSEvent dispatcher RESOLVED + SWALLOWED it — so AppKit's standard "Enter Full Screen" View-menu item never fired (system fullscreen was unreachable). Fix: `pane.spawnFloating` RELOCATED ⌃⌘F → **⌃⌘⇧F** (verified free; the ⌃⌘⇧ family is otherwise only resize / jump-failed arrows + brackets, no letter), and ⌃⌘F is left UNBOUND so the dispatcher passes it through to AppKit's standard Full-Screen item (no registry action / no menu shortcut to add — keeps the menu-shortcutless gate). Pinned by `TreeCommandRoutingTests` (⌃⌘F no longer routes to `.spawnFloating`; ⌃⌘⇧F does).
- ✅ **Keyboard copy-mode over the scrollback (⌘⇧C) — pragmatic, no programmatic char-select.** A modal copy-mode (tmux/zellij parity) over the existing ⌘F find + mouse selection: a COPY badge + keymap hint bar appear and keys drive scrollback instead of the shell — `j/k`/arrows line-scroll, `Ctrl-D/U` half-page, `g/G` top/bottom, `[`/`]` jump between OSC 133 prompt marks (all via libghostty binding actions verified against the pinned fork's `Binding.zig`), `/` reuses the existing find bar (`n/N` step), `y`/Enter copies, `q`/Esc exits. The `TerminalViewModel` is the single source of truth (the keyDown intercept is one guard delegating to a pure, unit-tested `handleCopyModeKey`). **No programmatic character-select** — the libghostty fork ABI has no set-selection action, so copy reads the existing mouse-made selection / whole scrollback, never a client-guessed range.
- ✅ **ES-E1-6 close-out (WI-6 population path): a flat `key = value` config file IS the user-visible source of `text:`/`csi:`/`esc:`/`unbind:` bindings.** WI-6 shipped the pure `KeybindGrammar` parser + the `textBindings`/`unbinds` model and WI-7 wired the dispatcher branch (`textBinding(for:)`→`sendBytes` / `isUnbound`→passthrough, before the action table), but NOTHING wrote those maps — so the literal-byte/unbind half of ES-E1-6 was unreachable end-to-end (review finding). `KeybindConfigLoader` (`SlopDeskVideoProtocol`, pure + headless) closes it: at launch `SlopDeskClientApp` reads `~/.config/slopdesk/config.toml` (honours `XDG_CONFIG_HOME`), parses each `keybind = <chord>:<action>` line via `KeybindGrammar.parseLine`, and FOLDS `text:`/`csi:`/`esc:` into `KeybindingPreferences.textBindings` + `unbind:` into `.unbinds`, then sets `preferences.keybindings` so the store's `didSet` republishes into `WorkspaceBindingRegistry.activeOverrides` (the same channel the GUI editor uses). Lenient flat-config dialect (`key = value`: `#` comments, blank lines, optional `=` whitespace + quotes, unknown keys silently ignored); **validate-then-drop** on a malformed `keybind` line (skip the line, the rest still loads — never trap, never abort the file). A missing/unreadable file is a no-op ⇒ a fresh install is behaviour-identical. NAMED actions (`cmd+1:goto_tab:1`) need the W6 action-id→`bindingID` map (a different module) so the loader exposes a `resolveNamedBinding` hook and DROPS named lines at launch (nil hook) — the text/csi/esc/unbind core needs no registry. No wire change, no golden key.
- ✅ **E15 fonts/prefs fidelity pass (2026-06-27) — `TerminalConfigBuilder` emits only keys VERIFIED in the pinned ghostty fork (`ThirdParty/ghostty/.work/ghostty-src/src/config/Config.zig`); every font setting actuates or is documented as a ceiling.** Five corrections, all CLIENT-side (no wire / golden touched). (1) **Font fallback was dead.** The builder emitted `font-family-fallback = …`, which is NOT a config key in the fork — silently dropped, so the J5 CJK/Nerd-Font chain never worked. Config.zig proves `font-family` is a `RepeatableString` and the FALLBACK CHAIN is expressed by REPEATING the key ("This configuration can be repeated multiple times to specify preferred fallback fonts when the requested codepoint is not available in the primary font"). FIX: emit the primary `font-family = <primary>` then one `font-family = <fallbackᵢ>` per comma-separated entry, in order, right after the primary (suppressed when the primary is empty — the first `font-family` must be the primary). (2) **Ligatures = Off did nothing.** Fonts that ship ligatures (Fira Code / JetBrains Mono) enable `calt` by DEFAULT in their GSUB, so "emit nothing" left them ON. Config.zig's `font-feature` docs the disabling form: "To generally disable most ligatures, use `-calt, -liga, -dlig`." FIX: `font-feature` is now ALWAYS emitted — `off` → `-calt,-liga,-dlig` (truly un-ligated), `calt` → `calt`, `dlig` → `calt,dlig`, alphabet flag appends `liga` only when ON. **This changes the DEFAULT builder output** (default ligatures = off ⇒ the default config now carries `font-feature = -calt,-liga,-dlig`); harmless for the default SF Mono (no ligatures) and correct for any ligature font. Client-render config only — the wire/golden corpus is untouched (the builder output is not on the wire; the change is pinned by `TerminalConfigBuilderTests`, not `golden_vectors.json`). (3) **Per-scope (Light/Dark-theme) font reached nothing.** `appearance.themeFonts[slug]` was persisted but `applyTerminal` fed the builder the raw `terminal.fontFamily`. FIX: a new `AppearanceApplier.resolveActiveThemeSlug` hook (`ThemeStore.active.id`) lets `PreferencesStore.applyTerminal` resolve the active scope's font via the pure `FontScopeResolver` (Global `terminal.fontFamily` wins everywhere — the "Global overrides theme" rule; else the active slot's per-theme font) and pass it as the builder's new `fontFamilyOverride`. A `nil` hook (headless) ⇒ Global stands ⇒ byte-identical default. (4) **⌘+/⌘-/⌘0 desync — single source of truth + size→reflow is CORRECT.** The zoom fired libghostty's INTERNAL `increase_font_size`, which the Settings "Size" stepper can't see → they desynced. FIX: the three `WorkspaceStore` font hooks now route through a new `onFontSizeStep` seam to `PreferencesStore.{increase,decrease,reset}FontSize()`, which mutate the ONE source of truth (`terminal.fontSize`, clamped 8…32 step 1 — the same scale as the stepper); the `terminal` `didSet` rebuilds the config + reflows the live surface (the SAME path the stepper drives). The old ES-E1-4 "without reflowing the PTY grid" note is CORRECTED: a font-SIZE change inherently resizes the cell box → the remote PTY grid reflows via SIGWINCH, and that is correct, not a bug — only font FAMILY/STYLE rebuilds are grid-preserving. (5) **New `TerminalPreferences` font fields no longer reset prefs on upgrade.** They were added non-optional; under SYNTHESIZED `Codable` an existing user's stored blob (missing those keys) decode-FAILED and reset every terminal pref once. RESOLVED via the established additive-tolerant pattern (the `KeybindingPreferences` `decodeIfPresent` precedent) — NOT a migration: a custom `TerminalPreferences.init(from:)` defaults every ABSENT key (defaults sourced from a default-constructed value so they can't drift from the memberwise init), so a pre-E15 blob SURVIVES; a key PRESENT with an invalid value (e.g. unknown `cursorStyle` raw) still throws ⇒ `PreferencesStore.decode`'s `try?` falls back to default (validate-then-default for corruption preserved). The underline-off / SGR-blink toggle and the `srgb-over`/`linear`/`perceptual` blending modes remain PERSISTED-but-not-emitted (no verified fork key — the documented ceiling, decision #5).

## Design-system overhaul (2026-06-21) — branch `feat/coding-workspace-redesign`, RE-SCOPES "NOT a theme rewrite"
- 🔁 **Supersedes the prior "disciplined application pass, NOT a theme rewrite" stance.** The user judged the application-only polish too shallow ("not just a bit of colour/border — research the modern solutions and RESTRUCTURE the design system, fix root causes"). A 9-agent research+audit pass (Warp / Linear / Raycast / Zed / Ghostty + design-token theory + macOS-native, against an internal audit) produced a concrete spec; 8 ranked root causes drove a 6-phase rebuild. The earlier `SlopDeskTheme`/`UIMetrics` token pair is retained as a **byte-identical compat shim** that now forwards to the new layer.
- ✅ **A real 3-layer token architecture (`Sources/SlopDeskClientUI/DesignSystem/`).** Primitive `DSPalette` (OKLCH-derived 12-step cool `ink` ramp n0..n12, never pure #000; indigo `accent` a9 #5E6AD2 = the new default, Linear-grade, still `DSThemeStore`-overridable; fixed-hue status ramp) → semantic `DSColor`/`DSType`/`DSSpace`/`DSRadius`/`DSElevation`/`DSMotion` (role tokens; a 13pt minor-third `DSFont` ladder carrying size+weight+design+leading+tracking; ONE 4pt spacing scale; a 5-level elevation ladder; tokenized springs) → per-component token structs (`PaneTokens`/…). View code reads only role/component tokens, so a palette swap or future light theme touches one layer. The two competing token systems (the #1 root cause) collapse to one source of truth.
- ✅ **The live-scale fix (P1) — `DSScale` is `@Observable` AND injected.** The legacy `UIScale` was `@Observable` but never injected into the SwiftUI graph (`UIMetrics` read `UIScale.shared` inside `static` vars → the density `NotificationCenter` post had zero subscribers → a density change silently never repainted). `DSScale` (+ `DSThemeStore`) is injected once via `.environment` at `WorkspaceRootView`, ABOVE the `SplitTreeView` no-teardown mount; the `.dsFont`/`.dsSpace`/`.dsFrame` modifiers read `@Environment(DSScale.self)` so the graph records the dependency and a tier flip live-reflows. **The reads are OPTIONAL (`DSScale?`) with a `.shared` fallback** — a view rendered outside the injection scope (the pre-connect `ConnectionGateView`, a sheet, a detached `NSHostingView`) returns nil instead of TRAPPING. (The non-optional form trapped at launch once P4 migrated the connection gate — an HW-only crash headless tests cannot see; the optional form is the durable fix.)
- ✅ **Depth from a surface-lightness ladder + hairline borders + an inner-top-edge highlight, shadow only at L4.** L0 sunken gutter / L1 window / L2 pane card / L3 chrome / L4 overlay. Terminal content panes stay FLAT OPAQUE (the libghostty IOSurface; the one-surface rule) — glass/material and the two tokenized drop-shadow profiles live ONLY on L4 overlays (⌘K palette, peek, floating title strip, connection gate). Focus is an accent ring/active-tab line gated on `controlActiveState == .key`, NEVER a dim.
- ✅ **A leak ratchet (`scripts/check-ds-leaks.sh`, wired into `make lint` + CI).** Greps `SlopDeskClientUI` view code (excluding `DesignSystem/` + the legacy shim files) for raw `.font(.system(size:N))` / `cornerRadius:N` and a scrim/shadow-colour scan over the 6 L4 overlay files; the overlay files are un-allowlisted (a new leak there fails immediately), ~10 out-of-scope files carry WARN-only `TODO(ds-migrate)` debt — a ratchet (no NEW leaks) not a one-shot burn-down. Proven by revert-to-confirm-fail.
- ✅ **Density tiers + tokenized motion + chrome-recede toggles (P5).** `Density {compact 0.92 / default 1.00 / comfortable 1.10}` replaces the font-only `UIScale.Preset`, driving the multiplier (fonts+padding) AND the chrome HEIGHT tokens (taken UNSCALED from the tier so they don't compound) — the end-to-end proof of the live-scale fix. `SLOPDESK_DENSITY` uses the default-OFF idiom (`== "1"` enables compact). Selection/focus/overlay animations use `DSMotion` springs gated behind `DSMotion.resolve(_, reduceMotion:)` (a translate collapses to opacity-only under Reduce Motion). Persisted Settings toggles let the status bar + block dividers hide so the tool recedes to pure terminal output.
- Phases (each: map → test-first → 3-lens adversarial review → full gate → HW-verify on macstudio → commit): P1 `cf9dcc8`, P2 `7ac103b`, P3a `a360b74`, P3b `905cb5c`, P4 `ebf6e85`, P5 `60153d4`. No wire change across any phase (golden byte-identical throughout).

## Client UI (chrome) — rewrite as a Warp design-system clone

- ✅ **RE-SCOPE — delete all prior client chrome attempts; rebuild the SwiftUI UI as a 1:1 clone of Warp's design
  system.** The infinite-canvas → flat-reskin → LG-glass / design-system P1–P5 line of chrome work is retired.
  We delete every view/chrome/design-token file in `SlopDeskClientUI` (and `SlopDeskInspector/InspectorViews`),
  KEEP all proven logic (the tree-of-intent domain, `WorkspaceStore`, `AppConnection`, terminal/block/search engines,
  agent-detect, the video/remote-window logic) and KEEP every seam (`TerminalRendererFactory`, `VideoWindowFactory`,
  `RemoteWindowDiscovery`, `SystemDialogDiscovery`, `TerminalSurface`). The wire/transport/FEC/host/golden core is
  untouched. → [REBUILD-PLAN], [deletion-manifest], [package-surgery]
- ✅ **Theme is an abstraction that DEFAULTS to Warp, not a hardcoded skin.** New headless `SlopDeskDesignSystem`
  module ports Warp's theme MODEL faithfully: a theme = a handful of seeds (`background`/`foreground`/`accent`/
  `cursor?`/`details`/16 ANSI) + the runtime derivation formulas (`neutral_n` = bg⊕fg@N%, `fg_overlay_n`,
  `accent_overlay_n`, contrast-picked text tiers, fixed `ui_*` literals). `WarpTheme` carries the Dark seeds
  verbatim (bg `#000000`, fg `#FFFFFF`, terminal/theme accent teal `#19AAD8`, Darker details). The agentic-UI brand
  orange is a SEPARATE constant (`#E8704E` color-model / footer brand tint `#D97757`), applied independently of the
  terminal accent. Future themes/extensions = new seeds + reused derivation. The module builds headless (SwiftUI
  value types only, no AppKit/UIKit/view bodies) and is unit-pinned, replacing the deleted `DS*Tests`. → [REBUILD-PLAN §1]
- ✅ **Single source of UI truth = the existing logic; views are thin.** The rebuilt UI binds ONLY the `.tree` path;
  every mutation goes through `WorkspaceStore` (never write `tree`); each leaf host view is keyed `.id(PaneID)`; the
  renderer + video views stay behind the seams so the library + tests stay headless (no `SCStream`/`VTCompression*`/
  `VTDecompression*`/Metal/`TerminalSurface` instantiated in a test). Proven logic is promoted into a new headless
  `SlopDeskWorkspaceCore` target; the rebuilt `SlopDeskClientUI` depends on Core + DesignSystem. AUTOCONNECT env
  seams and front-on-autoconnect are preserved in the new App scene. → [REBUILD-PLAN §1/§4], [logic-api-surface]
- ✅ **Cloned chrome surfaces (committed green, layer by layer):** window top bar (= Warp's 34pt tab bar with native
  macOS traffic lights + centered omnibar pill), left vertical-tab rail (248pt, control bar, pane-granularity rows
  with status icon + activity dot), pane split/divider/header (34pt, sub-text centered title, hover ⋮/×, accent corner
  triangle), terminal blocks + rich input bar + cwd pill, the claude-code agent bottom bar (surface-1 bar of radius-4
  hairline pills + green suggestion pill), and the overlay set (640×464 command palette / omnibar, 70%-scrim modal,
  toasts, ⋮ context menu). Build arc L0–L7 (delete+extract → tokens → chrome shell → panes → bottom bar → overlays →
  remote-window → odiff). → [REBUILD-PLAN §2/§3], [warp-* specs]
- ✅ **Verification = odiff pixel-diff against Warp, per-component, with class-based acceptance.** Capture Warp
  reference crops at fixed geometry/zoom; render the SwiftUI app via `scripts/check-macos.sh` (real Aqua + TCC, on
  macStudio, isolated home :7799) at the same geometry; `scripts/check-odiff.sh` slices the same crops and runs odiff.
  Flat chrome (bars/fills/borders/radii/overlays) must hit ≤1% changed pixels; text regions accept ≤6–8% (bundle
  Warp's Hack+Roboto to kill family drift — residual is glyph-edge AA only, since SwiftUI/CoreText ≠ Warp's GPU
  rasterizer); PTY/agent content + the agent status-hint line are EXCLUDED (they bleed through from libghostty/the CLI
  agent, not our chrome). → [REBUILD-PLAN §5]
- ⏸️/❓ **NOT wired today (greenfield, render chrome only):** `/remote-control`, File-explorer, and Rich-Input bottom-bar
  pills have NO existing logic subsystem; the green "Enable … notifications" suggestion pill has no host wire (dismissal
  persisted client-side). Build the pills as feature-flag stubs; treat real backing as later feature work. → [REBUILD-PLAN §4.3], [logic-api-surface §5.4]
- ✅ **FINAL theme = `#1D2022` default + `PureBlackDark` alternate.** The shipping default is `WarpTheme.dark`
  (`DesignTokens.warpDark`), background seed **#1D2022** — the live-Warp bundled chrome surface
  (`ColorU::from_u32(0x1D2022FF)`), so the slate the user actually SEES is reproduced exactly by the seed+derive model;
  the theme/terminal accent is teal #19AAD8 and the agentic brand orange (#E8704E / footer-brand #D97757) is a SEPARATE
  constant applied independently of the accent. A `PureBlackDark` alternate (`DesignTokens.pureBlack`) keeps the same
  derivation at background #000000 so the abstraction still offers a pure-black option. Adding a theme = new seeds +
  reused derivation; views never hardcode colors (contrast-pickers keep ink legible over any accent). The full UI
  architecture (3-module split, component inventory, env seams, the headless ImageRenderer odiff harness at full-window
  ≈ 3.64%) is documented in `docs/30-ui-architecture.md`. → [30-ui-architecture]

## Design system rebuild (2026-06-24) — RE-SCOPES the Warp-clone + native-bare chrome
- 🔁 **Supersedes both the Warp-clone design system AND the L0 "native bare system-colours" rebuild.** The Warp clone (`#1D2022` slate) and then the L0 rebuild (which DELETED `SlopDeskDesignSystem` for stock SwiftUI + system semantic colours) both missed; the user judged the native-bare UI too plain and chose to rebuild a CLEAN, token-driven design system from scratch. SwiftUI is NOT abandoned — it stays the composition layer; the change is a real token system + adopting external UI libraries (the "force pure-SwiftUI" stance is dropped).
- ✅ **The default chrome theme ("Paper") is a warm off-white light theme** — warm off-white (`#FCFBF9`/`#F5F4F0`), text `#37352F`, **green accent `#2B5A38`** — over a floating-rounded-CARD (radius 8) on a shared material/vibrancy backdrop; NOT amber (amber is reserved for the marketing logo only).
- ✅ **DNA: "clean / minimalist, floating card."** Card radius 8 / control radius 6; ultra-thin structure (borders ~6% opacity, hover ~5%); 8pt grid; NEUTRAL-gray row selection (`#E7E5DF`), accent used ONLY for active/focus; timing curves from `ReplicaKit.Anim` (EaseInOut/EaseOut, NO springs).
- ✅ **Token layer = a THIN, static namespace in `Sources/SlopDeskClientUI/DesignSystem/` (no separate SPM target — `SlopDeskDesignSystem` stays deleted).** `SlateTheme` carries BOTH `.paper` (default) + `.dark` (dual-theme; from design-tokens.css neutral grays + system-blue `#007aff`); static `Slate.{Surface,Text,Line,State,Status,Metric,Anim,Typeface}` read the active theme. Tokens are STATIC (not Environment) deliberately: SwiftUI `.preferredColorScheme`/Environment does NOT cross the `NSSplitViewController` AppKit boundary, so the window appearance is pinned in `SlopDeskSplitViewController.viewDidAppear` and colours are literal. Component kit: `SlatePlateButton`/`SlateSidebarRow`/`SlateSectionHeader`/`SlateStatusDot`/`SlateKeyValueRow`/`SlatePill`/`.slateCard()`.
- ✅ **First external SPM dependencies — attached ONLY to `SlopDeskClientUI`** (the headless core + codec/controller targets stay dependency-free; `swift test`/golden never fetch). swiftui-introspect 26.0.1 (clear the navigator NSScrollView bg for the sidebar vibrancy), SFSafeSymbols 7.0.0 (type-safe icons), Pow 1.0.6 (status-dot glow), KeyboardShortcuts 3.0.1 (macOS-gated, recorder/global-hotkey wiring deferred to the Settings layer). Trade-off: this RETIRES the "clean checkout builds with no prerequisite" property (SPM network resolution); versions pinned in `Package.resolved`.
- ✅ **iOS navigator = `List(selection:)`, macOS = custom `SlateSidebarRow` list.** The custom sidebar list gives macOS neutral-gray selection + full control (3 columns always visible in the split controller), but on a compact iPhone a button list does NOT drive `NavigationSplitView`'s push-to-content — so iOS keeps a system `List(selection:)` (matching the same visual style) whose selection navigates.
- ✅ **VERIFIED (macStudio): headless `make check` (3163 tests + golden byte-identical) · `check-ios.sh` BUILD SUCCEEDED · real macOS app via cua-driver (Paper chrome + live "+" add-tab) · real iOS app on iPhone-17-Pro sim via agent-device (Paper sidebar + push-to-card navigation).** Build arc L5–L10 (token layer → apply → sidebar/card → adopt libs → component kit → verify), each layer committed atomically.
- ⏸️ **OPEN — terminal CONTENT theme.** The terminal viewport (libghostty / placeholder) renders the dark terminal theme on both platforms, while the Paper chrome theme is light. This is the `PreferencesStore`/`TerminalConfigBuilder` axis (separately pinned warm-dark historically), NOT the chrome token layer — a deliberate follow-up decision, not changed here. → [30-ui-architecture]

## E1 default-keymap parity (2026-06-25) — epic E1, plan in [ui-shell/plans/E1.md](ui-shell/plans/E1.md)
- 🔁 **RE-SCOPE — tab cycling moves to `⌘⇧]`/`⌘⇧[`; plain `⌘]`/`⌘[` now drive sequential PANE cycling.** The old Muxy-parity pins bound `⌘]`/`⌘[` to `nextTab`/`prevTab`. The standard reference table lists `⌘⇧]`/`⌘⇧[` = next/prev TAB and `⌘]`/`⌘[` = focus next/prev PANE, and stories ES-E1-2/ES-E1-3 want sequential pane cycle on the bare bracket. **Decision: standardize on this layout.** `tab.next`→`⌘⇧]`, `tab.prev`→`⌘⇧[`; two NEW actions `cyclePaneNext` (`focus.cycleNext`, `⌘]`) / `cyclePanePrev` (`focus.cyclePrev`, `⌘[`) walk the active tab's panes in DFS order with wrap (`WorkspaceStore.cyclePaneFocusTree(forward:)`, no-op when <2 panes). These default-chord pins were ours to re-scope (they encoded the retired Muxy parity, NOT a wire/golden constant — no wire delta, no golden key); `TreeCommandRoutingTests.testDefaultChordsMatchTheDocumentedTable` is re-pinned to `⌘⇧]`/`⌘⇧[` with a code comment recording the move. Distinct from `⌃⌘]`/`⌃⌘[` (OSC-133 block jump) and `⌃⌘⇧]`/`⌃⌘⇧[` (jump-to-failed). → [ui-shell/plans/E1.md ES-E1-2]
- ✅ **Named-key (PageUp/PageDown/Home/End) scroll chords are an EXPLICIT exemption to the "every chord must be ⌘/⌥-prefixed" rule.** The §5 invariant (a workspace chord never steals a printable terminal key, so it must carry ⌘ or ⌥) protects *printable* keys only. The terminal-native scroll chords `⇧PageUp`/`⇧PageDown` (`view.scrollPageUp`/`scrollPageDown` → `scroll_page_fractional:±0.9`) and `⇧Home`/`⇧End` (`view.scrollTop`/`scrollBottom` → `scroll_to_top`/`scroll_to_bottom`) are ⇧-prefixed with a NON-PRINTABLE named base key — they cannot alias a terminal letter, so the ⌘/⌥ requirement does not apply. `⌘PageUp`/`⌘PageDown` (`view.cmdJumpPrev`/`cmdJumpNext`) reuse the existing `jumpToBlockInActivePane(delta:)` OSC-133 command-jump (not scroll). `TreeCommandRoutingTests.testEveryChordIsCommandOrOptionPrefixed` carries the exemption: a chord whose `key` ∈ {`.pageUp`,`.pageDown`,`.home`,`.end`} may be ⇧-prefixed; the rule stays in force (un-weakened) for every printable-key chord. → [ui-shell/plans/E1.md ES-E1-3 §5]
- ✅ **N6 menu-bar (OPTIONAL) — a SHORTCUT-LESS SwiftUI `.commands` menu over the SAME binding registry; chords stay owned by the `NSEvent` dispatcher.** `WorkspaceCommands` (`Sources/SlopDeskClientUI/Commands/WorkspaceCommands.swift`, `#if os(macOS)`) renders `WorkspaceBindingRegistry.groupedForDisplay` as one `CommandMenu` per category (Panes / Tabs / Sessions / Focus / View / Agents; the collapsed ⌘1…⌘9 representative expands into a real "Select Tab" submenu from `selectTabBindings`), attached to the `WindowGroup` via `.commands { WorkspaceCommands(store:) }`. Each item is a plain `Button(title) { WorkspaceBindingRegistry.route(action, to: store, …) }` dispatching through the single source of truth the keyboard layer already uses, with **NO `.keyboardShortcut`** — decisively: the app-level `WorkspaceKeyDispatcher` `NSEvent` `.keyDown` monitor OWNS chord dispatch (including the multi-key tmux/zellij prefix a `.keyboardShortcut` cannot express), so a menu shortcut would (a) **double-fire** alongside the monitor for a single chord and (b) **swallow** a prefix sequence's follow-up key before the terminal first responder (libghostty) consumes it. The chord glyph is appended to each title as a plain-text HINT (`"Split Right  ⌘D"`) so the menu stays a faithful cheat sheet without binding the key; items grey out via `requiresActivePane`. A source-level ratchet (`scripts/check-menu-shortcutless.sh`, wired into `make lint`) fails on a `.keyboardShortcut(` appearing as code in that file (revert-to-confirm-fail-proven). The menu adds no iOS surface and no wire/golden change; the overlay toggles (palette/cheat/find/peek-reply) are nil in E1 (those overlays land in later epics) → those actions stay graceful no-ops via `route`, never dead items. → [ui-shell/plans/E1.md WI-4 / N6]
- 🔁 **FIX (review) — Command Palette reconciled `⌘K` → `⌘⇧P`, and `⌘⇧R` reconciled `rename` → Toggle Details Panel.** Two E1 "parity" divergences shipped against the intended reference keymap and were locked in by a mis-named parity test. **(1)** `view.palette` (`.commandPalette`) was bound to the coding-IDE `⌘K`, but the standard default is `⌘⇧P` ("Opened with ⌘⇧P from anywhere"; the `OverlayCoordinator` already called it "the ⌘⇧P entry"). Re-bound to `⌘⇧P` (free — no other `p` chord); `⌘K` is now unbound. **(2)** `pane.rename` (`.renamePane`) squatted on `⌘⇧R`, which the reference keymap assigns to **Toggle Details Panel** (the command-palette.png screenshot shows "Toggle Details Panel ⇧⌘R"). The app-level `WorkspaceKeyDispatcher` `NSEvent` monitor intercepted `⌘⇧R` → rename and **swallowed** it, so `SlateTitlebar`'s hidden SwiftUI `.keyboardShortcut("r", …)` → `chrome.toggleInspector()` was a DEAD binding. **Decision: standardize on this layout.** A new `.toggleDetailsPanel` action OWNS `⌘⇧R`, routed (like the palette / cheat-sheet / find toggles) through a `toggleDetailsPanel` closure threaded `route → WorkspaceKeyDispatcher → WorkspaceCommands`; the live closure is installed by `WorkspaceRootView.onAppear` via `keyDispatcher.setToggleDetailsPanel { chrome.toggleInspector() }` (the dispatcher is built at app `init`, before the `WorkspaceChromeState` exists, so it is set after). Rename loses its chord (no dedicated rename chord is assigned) but stays a registered, routable action reachable from the title menu / context menu / palette (`chord: nil` ⇒ no hint chip, glyph derives `nil` from the registry — no desync). The titlebar's now-redundant `⌘⇧R` SwiftUI shortcut is removed (single owner per chord). (⌘⇧L sidebar was, at the time, left on the titlebar on the now-falsified assumption that the registry's `⌘B` sidebar binding meant the monitor wouldn't intercept `⌘⇧L` — see the follow-up review fix below, which moved the sidebar onto `⌘⇧L` through the monitor and dropped the titlebar shortcut too.) These default-chord pins were ours to re-scope (no wire/golden constant). `E1KeymapParityTests` re-pinned: palette = `⌘⇧P` (and `⌘K` freed), `.toggleDetailsPanel` = `⌘⇧R`, rename chord-less, and `.toggleDetailsPanel` routes without trapping (nil closure = no-op, supplied closure fires). → [ui-shell/plans/E1.md WI-4]
- 🔁 **FIX (review) — `⌘B` "Toggle Sidebar" was a DEAD chord on macOS; re-bound to `⌘⇧L` through the monitor + a `chrome` closure. And `⌘+` now grows the font (it was unbound).** **(1) Sidebar.** `view.toggleSidebar` was bound to `⌘B` and routed to `store.toggleSidebarCollapsed()` — but the macOS native split shell collapses the sidebar EXCLUSIVELY off `WorkspaceChromeState.sidebarCollapsed` (read by `SlopDeskSplitViewController.applyCollapse`); nothing reads `store.sidebarCollapsed` there. So `⌘B` flipped a legacy flag with no visible effect (the only working sidebar toggle was the titlebar's hidden `⌘⇧L` SwiftUI button). Re-bound to **`⌘⇧L` "Toggle Tabs Panel"**, routed (exactly like `.toggleDetailsPanel`) through a `toggleSidebar` closure threaded `route → WorkspaceKeyDispatcher → WorkspaceCommands`; the live closure is installed by `WorkspaceRootView.onAppear` via `keyDispatcher.setToggleSidebar { chrome.toggleSidebar() }`. The titlebar's now-redundant `⌘⇧L` SwiftUI shortcut is dropped (single owner per chord — the monitor swallows it first); the visible left-row plate button still toggles `chrome` on click. When no closure is supplied (headless/test/iOS) `.toggleSidebar` falls back to the store flag (a non-trapping graceful op, never a dead chord). **(2) `⌘+` font-increase.** The canonical font-grow chord is `⌘=`; the muscle-memory expectation is the `+` glyph (`⌘+`). On a US/ANSI layout `+` IS `Shift`+`=`, and `charactersIgnoringModifiers` (the dispatcher's base-key source) ignores `⌘/⌥/⌃` but NOT `⇧` — so physically pressing `⌘+` yields `KeyChord(character:"+", [.command,.shift])`, NOT `⌘=`; `KeyChord.init(character:)` lower-cases but never maps `+`→`=`. That chord was unbound, so `⌘+` leaked to the PTY and the font never grew. Added a tiny registry `aliasChords` map (the shifted main-row `+` and the keypad `+` → `.increaseFontSize`) folded into `chordTable` + `resolvedChordTable` (so the live dispatcher + tests resolve it) WITHOUT a display row (no duplicate cheat-sheet/palette entry; `binding(for:)` still returns the canonical `⌘=`). `E1KeymapParityTests` re-pinned: sidebar = `⌘⇧L` (and `⌘B` freed) + the route drives the supplied closure; `⌘+`/keypad-`+` resolve to `.increaseFontSize`. `TreeCommandRoutingTests` chord-count invariant updated to `#bindings + #aliasChords` (aliases share an action, never a chord). These default-chord pins were ours to re-scope (no wire/golden constant). → [ui-shell/plans/E1.md WI-4]
- 🔁 **FIX (review) — Focus-pane arrows reconciled `⌥⌘arrows` → `⌃⌘arrows`; the divider-move family moved off `⌃⌘arrows` → `⌃⌘⇧arrows`; and Zoom reconciled `⌥⌘↩` → `⌘⇧↩`.** Three E1 keymap-parity divergences against the intended reference table, none recorded as deliberate. **(1) Focus.** The most load-bearing pane-navigation set is **Focus pane up/down/left/right = `⌃⌘↑/↓/←/→`**. `WorkspaceBindingRegistry` bound `focus.left/right/up/down` to `⌥⌘arrows` and squatted `⌃⌘arrows` on **resize pane** — so a user expecting the standard convention pressing `⌃⌘→` got a divider RESIZE, not a focus move. **(2) Divider move.** The convention's "Move divider up/down/left/right" = `⌃⌘⇧↑/↓/←/→`. The resize family (`resizePaneLeft/Right/Up/Down`, the keyboard divider nudge) is re-pointed there, freeing `⌃⌘arrows` for focus; the action/routing is unchanged (still a sum-preserving divider nudge) — only the chord + display titles ("Move Divider …") move. **(3) Zoom.** "Zoom / unzoom split" = `⌘⇧↩`; `view.zoom` (`.toggleZoom`) was on `⌥⌘↩`. Re-bound to `⌘⇧↩` (free — the canvas-mode `CommandInterpreter` map ALREADY bound `.toggleZoom` to `⌘⇧↩`, so the registry was the lone diverger; the `⌥⌘arrows` focus slot is now free). The canvas-mode `CommandInterpreter` geometric-focus map (`.focus(.left/right/up/down)`) is moved `⌥⌘arrows` → `⌃⌘arrows` in lockstep so the two keymaps agree. **Decision: standardize on this layout** — these default-chord pins were ours to re-scope (no wire/golden constant). The swap is a clean transposition: `⌃⌘arrows` (was resize) → focus, `⌃⌘⇧arrows` (was free) → divider, `⌘⇧↩` (was free) → zoom, leaving `⌥⌘arrows`/`⌥⌘↩` free — uniqueness (`AttentionTests.testNoTwoBindingsShareAChord`) holds. `E1KeymapParityTests.testFocusDividerAndZoomChordsMatchSlateDefaults` (NEW) + `TreeCommandRoutingTests` pins re-asserted: focus = `⌃⌘arrows`, divider = `⌃⌘⇧arrows`, zoom = `⌘⇧↩`; `CommandInterpreterTests` focus pins re-asserted to `⌃⌘arrows`. → [ui-shell/plans/E1.md WI-4]

## E3 tree-path domain completion (2026-06-26) — epic E3, plan in [ui-shell/plans/E3.md](ui-shell/plans/E3.md)
- ✅ **A "window" close-scope maps to an slopdesk `Session` for close-confirmation + window close (WI-4).** Close-confirmation
  is configured per close-scope (pane / tab / window); slopdesk has no per-window object — the macOS
  NSWindow hosts the WHOLE `TreeWorkspace` (every session + its tabs). **Decision:** the notion of *window* is mapped to the
  **active `Session`**. `WorkspaceStore.requestCloseWindow()` evaluates the `closeConfirmWindow`
  `CloseConfirmationPolicy` against the **active session's `tabs.count`** (+ any busy pane in that session); when it
  must confirm it parks `pendingWindowClose = activeSessionID` (resolved by `confirmPendingWindowClose()` →
  `closeSession(activeSessionID)` / `cancelPendingWindowClose()`); when it need not, it is a pure no-op gate (it does
  NOT eagerly `closeSession` — a plain window close must preserve the persisted layout, not wipe it). The window →
  `Session` close action therefore fires only on the explicit confirm. The macOS `windowShouldClose` (a transparent
  forwarding `NSWindowDelegate` shim installed via the existing `.introspect(.window)` hook, `#if os(macOS)`) calls
  `requestCloseWindow()` and returns `false` only while `pendingWindowClose != nil` (block the NSWindow close while the
  confirmation resolves; otherwise the NSWindow closes normally). The pure decision lives in
  `CloseConfirmationPolicy.shouldConfirm(_:isBusy:tabCount:)` (`process` → busy-only, the pre-E3 guard byte-identical;
  `always` → always; `multiple_tabs` → `tabCount > 1`); the pane/tab close guards (`requestClosePaneTree`,
  `requestCloseActivePaneTree`, `closeActiveTab`) route through `closeConfirmationNeeded(scope:)` reading
  `closeConfirmTab`, so the default `.process` policy preserves the existing busy-shell behaviour. This default-chord/
  default-policy pin was ours to choose (no wire/golden constant). → [ui-shell/plans/E3.md WI-4]
- ✅ **OSC 7 cwd maps to the E4 host `cwd` RPC refreshed on OSC-133-D command completion (WI-2).** A pane's working directory could be sourced from the shell's OSC 7 escape; slopdesk's libghostty client-side OSC-7 callback is NOT in
  the `TerminalSurface` seam and would need `CGhostty` (untestable headless). **Decision:** the cwd-inheritance source
  is the E4 metadata `cwd` RPC (`MetadataClient.cwd()`), refreshed each prompt via the existing `onCommandCompleted`
  (OSC-133-D) hook — the OSC-7 *equivalent*, with no new wire message. `WorkingDirectoryPolicy.inherit` reads the SAME
  `PaneSpec.lastKnownCwd` the refresh writes (single source — the "don't double-source cwd" invariant). → [ui-shell/plans/E3.md WI-2]

## E7 settings parity + E1/E3 carry-overs (2026-06-26) — epic E7, plan in [ui-shell/plans/E7.md](ui-shell/plans/E7.md)
- 🔁 **RE-SCOPE — `⌘⇧W` reconciled Close Tab → Close Window; `⌘W` keeps the close cascade; slopdesk ships no Close-Tab
  chord (E7 carry-over #5).** The registry bound `⌘⇧W` to `.closeTab`, but the reference keymap
  lists **`⌘⇧W` = Close window**, `⌘W` = close focused
  pane/tab/window cascade, `⌘⇧T` = reopen — with **no dedicated Close-Tab chord**. **Decision: standardize on this layout.**
  A new `WorkspaceAction.closeWindow` (`requiresActivePane = false`) owns `⌘⇧W` via a `window.close` binding
  (`macwindow.badge.minus`, category `.tabs`), routed `routeTree(.closeWindow) → store.requestCloseWindow()` (the
  existing window-close gate that parks `pendingWindowClose` behind the `closeConfirmWindow` policy; the macOS
  `WindowCloseConfirmationDelegate` NSAlert / in-app surface resolves it). `tab.close` (`.closeTab`) becomes
  **chord-less** (`chord: nil`) — the Close Tab row stays in the palette / menu and tab close stays reachable via the
  `⌘W` cascade. `routeCanvas(.closeWindow)` is a graceful no-op (the retained-but-dead canvas has no window/session
  model). These default-chord pins were ours to re-scope (no wire/golden constant); `TreeCommandRoutingTests`
  re-pins `chord(.closeTab) == nil` + `chord(.closeWindow) == ⌘⇧W`, the chord-uniqueness invariant
  (`AttentionTests.testNoTwoBindingsShareAChord`) holds (Close Tab freed `⌘⇧W` before Close Window claimed it), and a
  routing test pins `.closeWindow → requestCloseWindow()`. → [ui-shell/plans/E7.md WI-7]
- ✅ **Pane-close confirmation gates by the Tab/Window policy ONLY on a cascading close (E7 carry-over #8).**
  `closeConfirmationNeeded(scope: .pane, …)` evaluated `closeConfirmTab` on EVERY pane close, so an `always` /
  `multiple_tabs` Tab policy confirmed even a mid-tab pane close that left its tab alive (never the intended behavior). **Decision:**
  the `.pane` arm now reads an `effectivePanePolicy(for:)` — `.process` (the busy-shell guard alone) for a
  NON-cascading close, the Tab policy when the close cascades its tab away (`tabRemovedByClosing(pane) ≠ nil`),
  escalated to the Window policy when that tab is its session's LAST. The `.tab` / `.window` scopes are unchanged. The
  in-app `CloseConfirmationPanel` subtitle now branches on the resolved policy via a pure
  `CloseConfirmationPanel.reason(for:scope:)` (process → "a process is still running"; always → "are you sure …
  pane/tab"; multiple_tabs → "this window has multiple tabs") fed by the store's `pendingCloseReasonPolicy`, replacing
  the hardcoded "a process is still running" (false for `always`/`multiple_tabs`) — carry-over #4. → [ui-shell/plans/E7.md WI-7]
- ✅ **"New Window" working-directory policy wired into `newSession` (E7 carry-over #7).**
  `SettingsKey.workingDirectoryNewWindow` (default `home`) was a DEAD accessor read nowhere. `WorkspaceStore.newSession`
  now resolves it against the active pane's `lastKnownCwd`, stamps `PaneSpec.lastKnownCwd`, and (terminal only) issues
  the deferred `cd` through the SAME `deferInheritedCwd` route + 1400 ms launch grace as `newTab` / `splitActivePane`
  (a `launchGrace`-parameterized core overload lets a test observe the `cd` at 0 ms). `home` resolves nil → no
  redundant `cd`. New-tab placement (`SettingsKey.newTabPosition`: after-current vs end) gains a store-level
  regression pin. → [ui-shell/plans/E7.md WI-7]

## E8 terminal interaction parity (2026-06-26) — epic E8, plan in [ui-shell/plans/E8.md](ui-shell/plans/E8.md)
- ✅ **E8 is wholly CLIENT-SIDE — no wire, no golden, no version bump.** The terminal renders in the CLIENT's libghostty (`GhosttySurface` behind the `TerminalSurface` seam); PATH 1 forwards raw VT bytes host→client→`feed()`→`ghostty_surface_write_output`, so every OSC-52 (clipboard) / OSC-22 (pointer-shape) / DECSET sequence a *remote* program emits already lands in the **client's** libghostty — no host round-trip, no `ClipboardWrite/Read` wire pair (the spec-mapping notes assuming a host-side libghostty are wrong for our architecture). The new fire-time `Defaults` keys are deliberately kept OFF the `EnvConfig` overlay / `video-prefs.json` sidecar (golden-safe by construction, exactly like the E7 stubs); `scripts/golden-check.sh` stays zero-diff. → [ui-shell/plans/E8.md §0,§7]
- ✅ **The bulk of E8 is a CONFIG-PASSTHROUGH job through the EXISTING live-reload pipeline, not new engines.** The vendored libghostty fork already implements almost every E8 knob as a native `Config.zig` key, so the PURE `TerminalControls` value type (`from(defaults:terminal:)`) → `TerminalConfigBuilder.string(...controls:)` → `PreferencesStore.applyTerminal()` / `refreshTerminalControls()` → live `ghostty_config_load_string` emits them in one stable block: `copy-on-select` (I4), `clipboard-trim-trailing-spaces` (I5), `selection-clear-on-typing` / `selection-clear-on-copy` (I6), `clipboard-paste-protection` / `clipboard-paste-bracketed-safe` (I9), `clipboard-read` / `clipboard-write` (I11), `mouse-hide-while-typing` (H9), `mouse-shift-capture` (H-shift), `cursor-click-to-move`, `mouse-reporting` (allow-mouse-capture), `mouse-scroll-multiplier`, the `cursor-color` / `cursor-text` / `cursor-opacity` render lines (H4/H5), and four `shift+<dir>=adjust_selection:<dir>` keybinds (I2; OFF → `unbind`). Empty colour strings are skipped (the "unset honoured" rule). `controls: nil` reproduces today's output byte-for-byte — pinned by `TerminalConfigBuilderControlsTests`. → [ui-shell/plans/E8.md §1, WI-2]
- ✅ **Paste-protection sheet + OSC-52 Ask REPLACE the blanket auto-approve (ES-E8-3 / ES-E8-6, I9/I11).** `confirm_read_clipboard_cb` used to auto-approve every request. It now branches on the C `request` arg: an unsafe-PASTE runs the PURE `PasteSafetyAnalyzer` (the analyzer's own four-danger criteria — multi-line / trailing-newline / `sudo`/`su` / control-char) and, on a warn, presents `PasteProtectionSheet` (Paste Anyway / Cancel); an OSC-52-READ honours the live `clipboard-read` access (Allow / Ask / Deny, default **Ask** — the riskier direction). **The embedder is the AUTHORITY, because libghostty's gate is NARROWER, not broader.** libghostty calls `confirm_read_clipboard_cb` ONLY when its own `input.paste.isSafe` is false, and `isSafe` flags ONLY a `\n` (or a literal bracketed-end `\x1b[201~`) — so a single-line `sudo`, an ESC-laced control-char paste, or a bare-`\r` paste are `isSafe == true` and never reached the callback at all (two of the four danger classes were silently suppressed). The fix runs the analyzer at the EMBEDDER's paste entry point (pure `PastePrecheck` → `GhosttyTerminalView.requestPaste`) BEFORE handing the bytes to libghostty, so all four danger classes confirm regardless of newlines; on approve we paste with `allow_unsafe` (the one-shot `pasteApprovedOnce` flag, consumed by `read_clipboard_cb`) so libghostty's own gate is not re-tripped into a SECOND dialog. The `confirm_read_clipboard_cb` PASTE branch stays as a BACKSTOP for a libghostty-initiated paste (e.g. middle-click) and now reads the LIVE `pasteProtection` toggle (not a hardcoded `true`). **De-risked cancel contract (the load-bearing discovery):** completing with `confirmed:false` + the original text RE-TRIPS the gate → unbounded recursion → crash, and the READ path re-trips on `confirmed:false` even with empty data. So a cancelled PASTE completes with EMPTY data (libghostty's `len==0` no-op frees the request), and EVERY READ completion uses `confirmed:true` (deny passes `""`, a well-formed empty OSC-52 reply that never leaks the clipboard). → [ui-shell/plans/E8.md WI-4, WI-6]
- ✅ **Paste-as… is a pure-transform + context-menu job, no wire (ES-E8-4, I10).** `PasteTransform` (`.bracketed` / `.shellEscaped` / `.base64(ofFileBytes:)`) + new `TerminalContextMenu` items (`pasteSelection` / `pasteFileBase64` / `pasteEscaped` / `pasteBracketed` / `pasteToComposer`, enablement-gated) + `contextMenuAction` wiring through `surface.text(_:)` / `NSOpenPanel` / the new `TerminalViewModel.onPasteToComposer` callback (a client-only buffer — no wire). → [ui-shell/plans/E8.md WI-5]
- ✅ **The genuinely-custom GUI wiring rides EXISTING libghostty hooks, all `#if os(macOS)`.** Right-click action (H7/H8) is owned END-TO-END by libghostty: the config builder (WI-2) emits `right-click-action = <RightClickAction.rawValue>` (the enum's raw values match the vendored fork's `RightClickAction` Zig enum 1:1 — `ignore`/`paste`/`copy`/`copy-or-paste`/`context-menu`), so the surface itself performs Copy / Paste / Copy-or-Paste / Ignore / Context-Menu and `rightMouseDown` keeps ONLY the ⌃-right-always-menu override (intercepted BEFORE forwarding the press). The earlier client-side `RightClickAction.effect` switch reimplemented the dispatch and read `hasSelection()` AFTER libghostty's default `context-menu` had already word-selected under the cursor → Copy-or-Paste always copied, Ignore/Paste left a stray highlight (the WI-7 review finding); `RightClickAction.effect` survives as the headless-pinned spec model. mouse-over-to-focus (H6) calls `model.onRequestFocus` from `mouseEntered`/`mouseMoved` gated by the pure `FocusFollowsMousePolicy` + live `Defaults` (slopdesk panes are separate surfaces, so libghostty's own `focus-follows-mouse` — which covers only its internal split tree — is insufficient); OSC-22 pointer shape (H14) extends `action_cb`'s `GHOSTTY_ACTION_MOUSE_SHAPE` → the pure `PointerShapeMapping` (validate-then-drop on an unknown raw int) → `NSCursor`, reset to arrow on `default`. All control values are read LIVE off `Defaults` at the event site so a Settings toggle takes effect on the very next event. → [ui-shell/plans/E8.md WI-7,WI-8,WI-9]
- ✅ **OMIT: cursor "Smooth" animation (H3).** The pinned libghostty fork exposes NO cursor-animation config key or hook. `TerminalPreferences.cursorAnimation` (`off` / `smooth`, default `off`) persists + surfaces in the Appearance → Cursor UI for forward-compatibility, but `TerminalConfigBuilder` emits no `cursor-animation` line (there is none to emit) — only `cursor-color` / `cursor-text` / `cursor-opacity` are live. Revisit if/when the fork adds the key. → [ui-shell/plans/E8.md §4 Cursor]
- ✅ **OMIT: undo "redo" at the prompt (I18).** `PromptEditPolicy` maps ⌘Z at an editable shell prompt (connected AND OSC-133 `shellActivity == .idle`, never on the alternate screen) to the readline UNDO control byte (Ctrl-_, `0x1F`); ⌘⇧Z / ⌘Y returns `nil` and FALLS THROUGH because **there is no portable readline redo** (readline binds undo but ships no standard redo keystroke). Off the prompt, ⌘Z stays an app/program key. → [ui-shell/plans/E8.md WI-11]
- ⏸️ **CEILING (deferred RENDERING): scroll-past overscroll + smooth-scroll (I14/I15, ES-E8-5).** The client libghostty OWNS the viewport and the pinned fork exposes **no overscroll-margin / sub-row-render / smooth-scroll API** (`Config.zig` has `scroll-to-bottom` but no `scroll-past-*` / `smooth-scroll`). What LANDS now: the `scrollPastLastLine` / `scrollPastFirstLine` / `smoothScroll` settings (persist + surface), the pure `ScrollPastPolicy.targetTopRow(...)` anchor arithmetic (integer `+`/`−`/`/` + ordered `max`/`min`, NO float/fma — pinned by `ScrollPastPolicyTests`), and the alt-screen **suppression gate** (both directions return `nil` on the alternate screen so a full-screen TUI keeps its own bottom edge). DEFERRED: the *blank-overscroll rendering* (floating the last/first row with the terminal background filling the gap) and *pixel-snap-on-gesture-end* — they need a libghostty viewport hook that does not exist; the policy is the testable anchor a future hook would clamp to. **ES-E8-5 is therefore a documented PARTIAL** (settings + policy + alt-screen gate land; overscroll RENDERING deferred). `ScrollPastPolicy.targetTopRow` / `minTopRow` are NOT yet called from `Sources/` (only their own tests reference them) — they are the dormant anchor, not a live path. Honest-disclosure: the Settings rows for Scroll Past Last/First + Smooth Scroll are relabelled "Preference saved; the overscroll rendering is deferred" / "the whole-row snap … is deferred" so the UI does not imply a behavior that does not occur. No fake overscroll is fabricated. → [ui-shell/plans/E8.md WI-12]
- 🚫 **CEILING (ABSENT, NOT degraded): backspace-deletes-selection (I7, ES-E8-2) ships default-OFF / not-yet-functional.** The pure `BackspaceSelectionPolicy` makes the 3-way decision (`deleteSelection` / `clearThenSingle` / `forward`, pinned by `BackspaceSelectionPolicyTests`), but the **actuation is impossible** on the pinned fork: it exposes no set-selection / cursor-geometry C API, so the embedder cannot prove a selection "ends at the cursor". A blind `(count−1)`-DEL pre-send for a mid-line selection would delete the WRONG characters — default-on data loss — so the GUI passes `selectionEndsAtCursor: false` and `leadingDeleteCount` returns 0. The net effect with the toggle ON is **indistinguishable from OFF** (a single character deleted + the highlight cleared via `selection-clear-on-typing`). **Honest-disclosure decision:** rather than ship a default-ON toggle that does nothing, the `Defaults.Key.backspaceDeletesSelection` default is now **`false`** and the Settings / All-Settings rows are relabelled "not yet functional"; this is a behavior that is ABSENT, not merely degraded. The policy + the `selectionEndsAtCursor` seam stay wired so a future libghostty geometry API lights up the faithful whole-run delete with no further change. → [ui-shell/plans/E8.md WI-10]
- ✅ **ACTUATION: clipboard-write "Ask" is now honored at `write_clipboard_cb` (I11, ES-E8 "actuation + honest-disclosure" cluster).** libghostty enforces `clipboard-write = deny` (never calls the write callback) and `allow` (calls it with `confirm == false`) itself, but DELEGATES `ask` to the embedder via the callback's `confirm == true` flag. The old `write_clipboard_cb` IGNORED that flag and wrote the pasteboard unconditionally, so the E8 "Ask" picker silently behaved like "Allow" — any remote OSC-52 could overwrite the system clipboard with no prompt. **Fix:** the pure, headless-tested `ClipboardWritePolicy.decide(confirmRequested:text:)` (→ `.write` / `.confirm` / `.drop`, pinned by `ClipboardWritePolicyTests`) is consulted in the callback; `.confirm` presents `PasteProtectionSheet(kind: .clipboardWrite)` ("Allow this program to set the clipboard?") and writes ONLY on approve, dropping on cancel — mirroring the OSC-52 READ-ask plumbing (WI-6). The `confirm` C `bool` imports as a Swift `Bool` (no `{0,1}` byte to re-read). iOS has no sheet, so an `ask` it cannot present DROPS the write (never silently allows). → [ui-shell/plans/E8.md WI-2]
- ✅ **HONEST GATE: the paste / backspace / scroll-past suppression now reads the REAL alt-screen flag, not `shellActivity == .running` (ES-E8-3 / ES-E8-2 / ES-E8-5).** The E8 GUI gates previously used `shellActivity == .running` as the `isAlternateScreen` proxy (and `slopdeskConfirmUnsafePaste` hardcoded `false`). `.running` is true for ANY foreground command (`cat`, a Python REPL, `npm install`), so the paste-protection sheet was OVER-skipped — pasting a `sudo` / multiline payload into a running non-TUI command suppressed the warning. `TerminalViewModel.isAlternateScreen` (a public read-only accessor over the client `TerminalModeTracker`'s real DECSET 1049/47/1047 parse, now fed UNCONDITIONALLY in `ingestPass`, pinned by `TerminalAlternateScreenTests`) replaces the proxy at every gate (`PastePrecheck`, the `confirm_read_clipboard_cb` paste backstop via a new `GhosttySurface.isAlternateScreen` hook, `BackspaceSelectionPolicy`, `PromptEditPolicy`), so the two paste paths agree and ONLY a true full-screen TUI suppresses. → [ui-shell/plans/E8.md WI-5]

## E9 details panel (2026-06-27) — epic E9, plan in [ui-shell/plans/E9.md](ui-shell/plans/E9.md)
- ✅ **Opaque host reads (`readAgentSession` / `gitDiff`) are bounded at the SOURCE to ≤ the 15 MiB opaque cap, so `cappedOpaque()` only trims an already-bounded tail (E9 carry-over #4, WI-2).** `HostMetadataProbe.readAgentSession` now opens a `FileHandle(forReadingFrom:)` and pulls at most `maxOpaqueReadBytes + 1` (a probe-side constant mirroring `MetadataResponseBuilder.defaultMaxOpaquePayloadBytes`) with `defer { try? handle.close() }` instead of slurping the whole file via `Data(contentsOf:)`; `runProcessData` (the `git diff` drain) replaces the single `readDataToEndOfFile()` with a byte-budgeted chunk loop over `availableData` that `process.terminate()`s + stops once the buffer is one byte past the cap — still draining-before-`waitUntilExit` so a large diff can't deadlock the pipe. The `+ 1` keeps the builder's "was truncated" signal alive. The loop predicate is the PURE `opaqueBudgetExceeded(_:)` helper (cap → false, cap + 1 → true), unit-pinned in `HostMetadataProbeParsingTests` with no I/O while the `FileHandle` / `Process` paths stay compiled-and-reviewed only (hang-safety). → [ui-shell/plans/E9.md WI-2]
- ✅ **Codex agent auto-enumeration is intentionally DEFERRED (Claude-first scope reduction), not deleted (E9 carry-over #3, WI-3).** `HostMetadataProbe.listAgentSessions` auto-enumerates Claude + opencode but deliberately adds NO `codexSessions` enumerator, so a `~/.codex/sessions` transcript is never auto-discovered. The codex scaffolding stays intact ON PURPOSE — `AgentKind.codex`, the `~/.codex/sessions` root in `sessionRoots()`, and `readAgentSession`'s codex read path are KEPT so an EXPLICIT absolute codex session id still reads on-disk (the shipped E4 capability); only the auto-discovery half is deferred while the explicit-id read path stays live. E9 surfaces only Claude as the first-class agent in the Details panel. Documentation/comments only — NO code behavior change (doc comments at `listAgentSessions` + `sessionRoots`, this note). → [ui-shell/plans/E9.md WI-3]
- ✅ **Outline tab = command-mark navigator for ALL panes; agent-prompt rows are a DOCUMENTED PARTIAL (ES-E9-2, WI-5).** The new `OutlineView` (Details tab between Info and Git, `list.bullet` icon) renders the active pane's `TerminalBlockModel` as a flat CHRONOLOGICAL (oldest→newest) list — left exit gutter (green ✓ `Slate.Status.ok` / red ✗ `Slate.Status.err` / grey · `Slate.Text.tertiary`, via the pure `OutlinePresentation.gutter`), truncated `commandText`, right relative timestamp (`OutlinePresentation.relativeTime` over the CLIENT-receive `firstSeen` time — no host clock on the wire). Tap → `WorkspaceStore.jumpToNavigatorBlockInActivePane`; right-click → "Jump to" + "Copy" (NSPasteboard/UIPasteboard). Agent session history PROMPTS are not surfaced here — SlopDesk carries no prompt-mark wire signal (the block index is shell command marks only); under the Claude-first scope reduction E9 renders the command-mark Outline faithfully for BOTH terminal and agent panes (the agent's shell marks ARE captured) and DEFERS prompt-row decoration — no prompt row is invented. The segmented Details header is kept (no horizontal tab bar — scope reduction honored). → [ui-shell/plans/E9.md WI-5]

## E12 composer (2026-06-27) — epic E12, plan in [ui-shell/plans/E12.md](ui-shell/plans/E12.md)
- 🔁 **REVERSAL — the Composer field is a HOSTED `NSTextView`/`UITextView` (`ComposerTextEditor`/`ComposerTextView`), NOT the pure-SwiftUI `TextField`-on-`InputBar` the E12 plan called for.** The E12 plan (`E12.md` ES-E12-3 + the `ComposerBar` file note) scoped the field as a SwiftUI overlay whose `⌘V`/`⇧⌘V` rich/plain paste rode `.onKeyPress` — i.e. **no hosted view needed**. The final E12 pass overturned that: on macOS the **Edit ▸ Paste menu item owns the `⌘V` key-equivalent and dispatches `paste(_:)` to the focused field BEFORE any SwiftUI `.onKeyPress` handler runs** (the app keeps the standard `.pasteboard` command group), so a pure-SwiftUI field can NEVER intercept `⌘V` to run the HTML/RTF→Markdown conversion — the conversion was dead on macOS. The only reliable interception is OVERRIDING the text view's `paste(_:)`, which requires hosting a real `NSTextView` (macOS) / `UITextView` (iOS). Hosting also delivers the **caret-aware splice** (insert at the live selection, the same seam the right-click "Paste and continue in Composer" path uses) and full cursor/selection control that a SwiftUI `TextField` can't express. The pure pieces are preserved and still headless: the Return decision stays `ComposerKeyResolver` (pinned by `ComposerKeyResolverTests`); the paste read+convert stays `ComposerPasteboard`/`ComposerPasteHandler` over `RichPasteMarkdown` (pinned by `ComposerPasteHandlerTests`, NSPasteboard-only, no window). This note SUPERSEDES the "SwiftUI composer overlay … `⌘V`/`⇧⌘V` … keypress handling" framing in `E12.md`. → [ui-shell/plans/E12.md ES-E12-3]
- ✅ **Long-tail hardening of the hosted `ComposerTextView` (E12 final-pass review, LOW-severity cluster).** Five residual fixes to the new coordinator, all client-only, no wire/golden touch: **(1) IME-safe `⎋`** — `keyDown` only treats Escape as composer-cancel when there is NO marked text (`ComposerKeyResolver.escapeCancels(hasMarkedText:)`, pinned); while an IME composition is in flight the event is routed through `inputContext?.handleEvent(_:)` so Escape drops the marked text (Telex/Pinyin/Kotoeri) instead of tearing down the Composer. **(2) Rich-only paste** — `richMarkdown()` reads HTML/RTF/image even when NO plain `.string` flavour is present, and the macOS field advertises `.html`/`.rtf`/`.png`/`.tiff` in `readablePasteboardTypes` (iOS: `canPerformAction` adds `public.html`/`public.rtf`) so AppKit/UIKit ENABLE Paste for a rich-only clipboard and route `⌘V` into the override (pinned by `ComposerPasteHandlerTests`). **(3) Undoable paste** — the converted paste is applied through the text view's edit path (macOS `shouldChangeText`/`textStorage`/`didChangeText`; iOS `replace(_:withText:)`/`insertText`) with the coordinator vending an `UndoManager` via `undoManager(for:)`, so `⌘Z` undoes the pasted block as one edit (pinned). **(4) Placeholder repaint** — a placeholder change while the field is open + empty (`⌘⇧M` queue-mode flip) marks `needsDisplay` via the pure `placeholderNeedsRedraw(old:new:isEmpty:)` guard (no per-keystroke redraw; pinned). **(5)** this DECISIONS reversal (item above). → [ui-shell/plans/E12.md ES-E12-3]

## E17 read-only + vi-mode pill + secure input (2026-06-27) — epic E17, plan in [ui-shell/plans/E17.md](ui-shell/plans/E17.md)
- 🚫 **CEILING (char-range vi selection is ABSENT, not faked): the vi repeat-count + visual-mode state is REAL and observable, but a char-range selection cannot be STARTED from a vi cursor (ES-E17-2/3, WI-4).** The E17 vi-mode layer rides the EXISTING modal copy-mode engine (`TerminalViewModel.handleCopyModeKey`, P5b) — no second engine. WI-4 adds, purely client-side (no wire, no golden): a pure `CopyModeState` (pending repeat-count + `VisualMode {none,char,line,block}`) with observable `viPendingCount`/`viVisualMode` mirrors (the `isCopyMode`/`copyModeBadgeActive` `@ObservationIgnored`-twin idiom, so the keyDown intercept never registers a SwiftUI dependency), driving the WI-5 pill; **repeat-count** (`1`–`9`, and `0` once a count is pending) that accumulates and applies to the NEXT motion then clears — it SCALES a parameterized libghostty action (`scroll_page_lines:±count`, `jump_to_prompt:±count`) and REPEATS a directional one (`adjust_selection:<dir>`, `navigate_search:…` ×count, which take no magnitude), with absolute jumps (`g`/`G`) and half-page (`⌃d`/`⌃u`) just consuming/clearing the count, clamped to `maxCount = 9999`; **`?`** opens the SAME find bar as `/` biased BACKWARD (new `onRequestFindBackward` hook, falling back to `onRequestFind` so the key is never dead before the GUI wires the bias); **visual modes** `v`/`V`/`⌃v` set the mode (pill `VISUAL`/`VISUAL LINE`/`VISUAL BLOCK`) and switch the line motions to `adjust_selection:<dir>` selection-EXTEND; **`y`/Enter** copy the mouse-made selection / visible scrollback (the unchanged `copyCurrentSelectionOrScrollback` path) and now EXIT vi mode per spec; and a `showViKeyHints` observable + `onRequestViKeyHints` hook for the `⌘/` key-hint bar (off by default, reset per session). **The ceiling:** the pinned libghostty fork exposes NO programmatic cursor-move / set-selection / swap-ends C API, so a vi cursor cannot START a char-range selection from nothing, there is NO rendered vi visual-char-select, and `o` (anchor-swap) is a documented NO-OP (emits nothing — never a faked cursor move, the anti-jitter rule: never claim a position libghostty can contradict). The pill shows TRUE mode state; selection EXTEND (`adjust_selection`) + yank work only against an anchored MOUSE-made selection. The `adjust_selection`'s exact reach is to be re-confirmed against real libghostty during the GUI gate; the WI-4 layer is fully unit-pinned headless by `TerminalViewModelViMotionTests` (+ the base `CopyModeTests`). → [ui-shell/plans/E17.md WI-4]
- ✅ **WIRE EXTENSION (golden corpus touched): a new CONTROL type 31 `inputEcho(enabled:)` (host → client) is REQUIRED — the no-echo state is genuinely off-stream (ES-E17-4, WI-6).** Secure Keyboard Entry must engage AUTOMATICALLY when the remote shell shows a hidden-password prompt; the trigger is the PTY's termios `ECHO` flag being cleared on the HOST by the child (`sudo`/`ssh`/`login`/`read -s`/`getpass`). I first tried client-side derivation per the carryover, but termios `ECHO` is a host-side line-discipline attribute set with `tcsetattr` — it is **NOT in the output byte stream at all** (the client's `TerminalModeTracker` only sees DECSET/DECRST + OSC-133), and a "Password:"-text heuristic is locale-fragile (violates the honesty rule). So the AUTO path genuinely needs a new host→client message — the carryover's sanctioned wire-extension case. Design: **type 31** `inputEcho(enabled: Bool)`, CONTROL, 1-byte body (`enabled ? 1 : 0`), decoded `byte != 0` (untrusted-bool rule), validate-then-drop on a short body (`truncated`), forward-tolerant of trailing bytes (matches the file's fixed-field decoders). `wireByteCount == 1 + 1 + 4` pinned by `WireMessageWireByteCountTests`; encode/decode/round-trip/short-drop pinned by `WireMessageInputEchoTests`; corevectors emits both `inputEcho` keys (`000000021f00` / `000000021f01`) and they were **hand-merged** into `golden/golden_vectors.json` so the 13 XCTest-frozen keys survive (`golden-check.sh` zero-diff). Additive within wire version 1 (host accepts only v1, no negotiation) → **host + client redeploy together** (no-backcompat); an older peer DROPS type 31 cleanly (`unknownMessageType`). The pre-existing `ClaudeWireCodecTests.testUnknownTypeByteDropsNotTraps` was updated (it used `31` as a sample UNASSIGNED tag → swapped to `17`, still unassigned). **Host detect:** new `EchoModeWatcher.swift` mirrors `ForegroundProcessWatcher.swift`'s pure-core / thin-shim split — pure `EchoModeDetector` (edge-only emit, unit-pinned by `EchoModeWatcherTests` by feeding bools) + thin `PTYEchoProbe` (`tcgetattr` → `ECHO` bit, defaults to echo-on on any failure so a probe error NEVER spuriously locks the keyboard; compiled+reviewed only, never spun in a test). The detector is anchored at **echo-on** (the client's assumed default), so it stays SILENT in the steady state — the CONTROL stream is byte-identical to the pre-feature one when no no-echo prompt ever appears (a deliberate divergence from `ForegroundProcessDetector`'s nil-anchor first-emit, since a redundant initial `inputEcho(true)` would be pure noise). `MuxChannelSession` drives the probe right after writing client input to the PTY (where `ECHO` flips fastest around a password prompt) plus the low-rate foreground poll as a backstop. The CLIENT manager + `SECURE INPUT` pill + Auto/Indicator settings are WI-7 (macOS-only `EnableSecureEventInput`, balanced); WI-6 ships only the wire + host detect, so the wire round-trip is provable headless before the GUI lands. → [ui-shell/plans/E17.md WI-6]
- 🔁 **FIX (review): vi `?` backward-find WIRED end-to-end, the dead `o` hint REMOVED, and Vi Mode gains an entry chord + discoverable commands.** Three E17 vi-mode review findings, no wire/golden touched. **(1) `?` backward search (ES-E17-3).** `handleCopyModeKey`'s `?` already routed to `onRequestFindBackward ?? onRequestFind`, but `onRequestFindBackward` was never ASSIGNED (the leaf wired only find/next/prev) so `?` always fell back to the FORWARD bar. `TerminalFindBarModel` gained `open(backward:)` + a `searchBackward` field; its `n`/`N` (`next()`/`previous()`) now step RELATIVE to that direction (`n` = same direction as the search, `N` = opposite — vim parity), and `TerminalLeafView.wireFindCallbacks()` assigns `onRequestFindBackward = { bar.open(backward: true) }` (cleared alongside the others). The copy-mode `n`/`N` KEYS stay pinned to libghostty's own `navigate_search:next/previous` (the fork has no search-direction concept) — the direction bias lives in the find bar, which owns it. **(2) Dead `o` hint REMOVED (honesty).** The `ViKeyHintBar` advertised `o` "Swap ends" while the `o` case is a documented NO-OP; verified the pinned fork exposes no swap-ends API (`Binding.zig` has `adjust_selection` + `select_all` only) — case **(a)** held, so the row is removed (consistent with the already-omitted dead motions), pinned by `ViKeyHintBarTests` over a new `advertisedKeys` surface. **(3) Vi Mode entry chord + commands (fidelity).** The reference Enter-Vi-Mode chord is ⌃⇧Space; slopdesk reused the pre-existing ⌘⇧C "Copy Mode" with no ⌃⇧Space and no "Vi Mode" name. The `view.copyMode` row is retitled **"Vi Mode"** (keeping "copy mode" in keywords), ⌃⇧Space is folded in as a SECOND resolving chord via `aliasChords` (the ⌘+ font-increase idiom — no extra display row, ⌘⇧C stays the display chord), needing a new NAMED `KeyChord.Key.space` (keyCode 49) that the macOS normalizer maps ONLY when a non-shift modifier is held (a bare/⇧ Space still types — the §5 bare-key rule is intact, and the alias sidesteps the printable-key prefix guard, which only iterates `allBindings`). A new discoverable **"Vi Mode Key Hints"** command (`.toggleViKeyHints`, chord-less — `⌘/` is owned by the cheat sheet contextually) routes to `toggleViKeyHintsInActivePane()`. Pinned by `TreeCommandRoutingTests` / `ViKeyHintsRoutingTests` / `KeyChordNormalizerTests` / `TerminalFindBarModelTests`. **DEFERRED:** a separate **"Mark Mode"** feature is intentionally OUT of E17 scope (not built). → [ui-shell/plans/E17.md review]

## E10 path/link detection + status bar (2026-06-27) — epic E10, plan in [ui-shell/plans/E10.md](ui-shell/plans/E10.md)
- ✅ **E10 WI-3 link & status-bar config keys are CLIENT-SIDE fire-time `Defaults.Keys`, golden-safe by construction (like the E7/E8 stubs).** Added `linkDetection` (`controls.linkDetection`, default ON), `linkCmdClickKey` (`LinkCmdClick` = `open`/`copy`/`nothing`, default `open`), `linkCmdShiftClickKey` (`LinkCmdShiftClick` = `reveal-finder`/`open-system-default`, default `reveal-finder`), `autoDetectLinkSchemesKey` (`AutoDetectLinkSchemes` = `all`/`custom`, default `all`), `customLinkSchemes` (`[String]`), and the WI-9 forward-stubs `hintPatterns` / `hintPatternActions` (`[String]`). The three new enums live beside the E8 Controls enums in `TerminalControls.swift`, each `String`-raw with a non-failable validate-then-repair `init(rawValue:)` so the `Defaults.PreferRawRepresentable` bridge can never trap on a future-version value. The existing `hideStatusBar` key is REUSED (not re-added) — the status-bar hide toggle stays in Appearance → Chrome. `SettingsKey.linkSchemePolicy` is the ONE bridge from the persisted (mode + custom list) into the detector's richer `LinkSchemePolicy` (the seam WI-5/8/9 read). Pinned by `SettingsKeyTests` (defaults / round-trip / stale-repair / wire strings) + the `AllSettingsCatalog` coverage test. → [ui-shell/plans/E10.md WI-3]
- 🚫 **CEILING (Open-With per-target surrogates ABSENT, not faked): a per-target "Open Links/Files/Folders With → Browser/App/Finder" picker is NOT shipped — the actionable `link-cmd-click` / `link-cmd-shift-click` config keys are surfaced instead.** Letting each target type open in a LOCAL file / folder / web pane is not something slopdesk can offer for a REMOTE host: the files live on the host and there is no file-transfer sub-protocol (files-and-links mapping #2/#3) and no `.web`/`.folder` PaneKind. Rather than ship a dead per-target picker (a control that lies about behaviour), the Controls → **Open With** section surfaces the two config keys that DO actuate — `link-cmd-click` (Open best-handler / Copy / Do Nothing) and `link-cmd-shift-click` (Reveal in host Finder / Open with host system-default) — plus a footnote documenting that paths reveal/open on the HOST and URLs open in the CLIENT browser. The **Link Schemes** section (Auto-Detect All/Custom + a comma-separated Custom list editor) is fully actionable. A "Default Git Client" / "Custom Open With Apps" / "Reset Security Warnings" row set is likewise omitted as deferred-until-backed (no per-app launch table, no git-GUI registry, no security-warning store yet). → [ui-shell/plans/E10.md WI-3]
- ✅ **E10 WI-7 Open/Reveal are TWO new `MetadataVerb` bytes on the EXISTING E4 RPC (no new wire type, envelope byte-identical), the ONLY side-effecting verbs.** Host Open-in-default-app / Reveal-in-Finder is the one wire decision point of E10 — the file lives on the HOST Mac, not the client. Per the E4 carryover this rides the existing `metadataRequest`(16)/`metadataResponse`(30) pair by adding `MetadataVerb.openPath = 9` / `.revealPath = 10` (request payload = raw UTF-8 absolute host path; response = empty payload + status). The envelope encode/decode is unchanged (the verb is already an opaque `UInt8`, forward-tolerant — an unknown verb → `unsupportedVerb`, never a trap), so there is NO new message type and NO envelope-codec change; the golden corpus gains ONE representative `openPath` request sample (`metadataWireMessages`, verb 9, requestID `0x0A0B0C0D`, path `/Users/me/project/main.swift`), hand-merged so the 13 frozen XCTest-pinned keys survive. The host routes 9/10 to a thin `#if os(macOS)` `HostPathActionPerformer` (`NSWorkspace.open` / `activateFileViewerSelecting`) inside `serveMetadata` BEFORE the pure read-only `MetadataResponseBuilder` (which stays read-only — its now-exhaustive switch answers `.error` defensively if a side-effecting verb ever reaches it, performing no side effect). The performer is compiled + code-reviewed ONLY (the hang-safety rule — `NSWorkspace` needs a window-server + Launch Services session, like `HostMetadataProbe`); the CLIENT routing (`MetadataClient.openPath`/`revealPath` → verb 9/10 + raw-UTF-8 payload, `true` only on `.ok`) is the unit-tested half (`PathActionRoutingTests`). → [ui-shell/plans/E10.md WI-7]
- 🔓 **E10 WI-7 CONFINEMENT: open/reveal accept ANY absolute host path WITHOUT cwd-subtree confinement — DELIBERATELY divergent from the E4 read verbs.** The read verbs (`gitDiff`/`listDirectory`/`readAgentSession`) confine their path arg to the pane cwd subtree because they stream host file CONTENTS back over the wire (a `listDirectory("/etc")` would exfiltrate). `openPath`/`revealPath` return ONLY a status byte + empty payload — no host bytes ever cross the wire — so there is nothing to exfiltrate and the design affordance is to ⌘click ANY detected path (incl. one outside the repo, e.g. `/usr/local/bin/foo` or `~/other-project`). Confining them would break the feature for no security gain (the boundary is the trusted WireGuard mesh; no app-layer crypto). They are STILL validated defensively — a leading `~` is expanded against the HOST home, then the path must be ABSOLUTE (empty/relative → `error`) and must EXIST (`notFound` if gone), never force-unwrap, never trap. iOS has no Finder and no ⌘: the iOS client routes open/reveal TO the host over this same wire (it never opens locally). → [ui-shell/plans/E10.md WI-7]
- ⚠️ **E10 WI-9 DISPLACES a shipped chord: `.peekAndReply` RE-POINTED ⌘⇧J → ⌘⌥J so Hint Mode can OWN ⌘⇧J for "Hint to Open" (the E10 carryover binding "E10 OWNS ⌘⇧J for Hint Mode").** The reference Hint Mode defaults are ⌘⇧J open / ⌘⇧Y copy / ⌘⇧R reveal. ⌘⇧J was the shipped P4 Peek & Reply chord (`PeekReplyTests`/`TreeCommandRoutingTests`-pinned); it moved to ⌘⌥J (FREE — no `option+command` `j`; keeps the "J = jump-in/peek" mnemonic; a menu/palette-surfaced supervision action, so muscle-memory impact is minimal). ⌘⇧Y (Hint to Copy) was FREE. Tests + the `view.peekReply` comment updated. → [ui-shell/plans/E10.md WI-9]
- 🚫 **E10 WI-9 DIVERGENCE: "Hint to Reveal in Finder" is CHORD-LESS (⌘⇧R is slopdesk's Toggle Details, kept).** The reference keymap binds reveal to ⌘⇧R, but ⌘⇧R is the shipped Toggle Details Panel (`view.toggleDetails`, `E1KeymapParityTests`-pinned). The E10 carryover mandates ONLY ⌘⇧J for hints, so `.hintToReveal` ships `chord: nil` — palette/menu-surfaced + reachable as an in-overlay action switch while hint mode is up; the user may bind it in Settings. Taking ⌘⇧R from Toggle Details would be a worse regression than leaving reveal chord-less. → [ui-shell/plans/E10.md WI-9]
- ✅ **E10 WI-9 Hint Mode is a pure client-side overlay over the WI-1 detector + WI-2 cell geometry — labels are STABLE per session (snapshot at entry, never re-detected per keystroke).** `HintLabelAssigner` (pure, headless-tested) detects hintable targets by REUSING `TerminalLinkDetector` for paths/URLs/`file://`/`mailto:` (cell-accurate columns) and adds git-hash (`[0-9a-f]{7,40}` with ≥1 hex LETTER so a long decimal isn't a hash), IPv4 (octet-validated in-regex), and user `hint-pattern` regex forms — each EXTRA match dropped if it overlaps an already-accepted span (a hex inside a URL never double-lights). It assigns collision-free EXACTLY-2-letter Vimium labels (first letter cycles fastest so survivors spread on the first keystroke; bounded at alphabet²) and a pure `filter(typed:)` dims on the first letter / confirms on the second (no Enter). The mode lives on `TerminalViewModel` (`beginHint`/`handleHintKey`/`confirmHintTarget`/`cancelHintMode`) so the macOS renderer's `keyDown` (mirroring the copy-mode intercept, incl. the release-swallow) and the iOS tap-on-label fallback share ONE engine; the overlay only RENDERS the pure state (yellow black-text badges via the WI-2 `TerminalCellMetrics`, dimmed surface, `HINTS` badge). Actuation reuses the SAME `LinkActionPolicy` as ⌘click/Jump-To (open path → host RPC, URL → client, copy → client pasteboard, reveal → host RPC); a custom `hint-pattern` action runs a known-safe `open <url>` on the client else verbatim on the HOST shell. CEILING: a "Hint to copy" design could also scan SCROLLBACK, but a badge can only be SHOWN over a visible cell, so all three intents scan the visible viewport (scrollback-copy deferred). → [ui-shell/plans/E10.md WI-9]
- 🚫 **E10 ACCEPTED CEILING (audit `osc8-hyperlinks-not-in-hint-or-jumpto`): OSC 8 hyperlink RUNS are NOT surfaced in Hint Mode / Jump-To — a renderer-target-only libghostty gap, not reachable from the headless seam.** `hint-mode.md`/`files-and-links.md` list "OSC 8 hyperlinks" among hintable/jump-to targets, but `HintLabelAssigner.targets` + `JumpToModel`/`OpenQuicklyView` feed ONLY the plain-text `TerminalLinkDetector` regex scan — so an OSC 8 link whose DISPLAY text is not itself a URL/path (text `click here` → `https://…`) gets no hint label and no Jump-To row. Surfacing it would need the OSC 8 URL per cell, which the viewport snapshot seam cannot provide: `ghostty_surface_read_text` returns `ghostty_text_s` (`tl_px_x/tl_px_y/offset_start/offset_len/text/text_len` — **no hyperlink field**), and the ONLY OSC 8 URL access in the vendored `ghostty.h` is `GHOSTTY_ACTION_MOUSE_OVER_LINK` (`{url; len}`), a HOVER callback for the single link under the MOUSE, NOT a viewport-grid run enumeration. A keyboard hint/jump merge would require a NEW libghostty C API (per-cell hyperlink ID/URL read) + a vendored-fork patch + an xcframework rebuild (the fragile Zig/SDK step) — none reachable from `SlopDeskWorkspaceCore`. Accepted honest gap: libghostty's hover-underline + ⌘-click still open OSC 8 links for the MOUSE; only the keyboard hint/jump surfaces miss the display-text-isn't-a-URL case. Revisit if a cell-hyperlink read API lands. → [ui-shell/plans/E10.md "Accepted ceiling — OSC 8"]
- 🔁 **FIX (Batch-4 audit `links-jump-statusbar-hint`): Hint-to-OPEN on an IP now BROWSES (`http://<ip>`); a bare git-hash KEEPS copy as a deliberate gap.** `TerminalLeafView.performHintAction` mapped BOTH `.ipAddress` and `.gitHash` straight to `copyToPasteboard` for every intent, so ⌘⇧J "Hint to Open" on a dotted-quad silently COPIED instead of opening. **IP fix:** the `.open` intent now opens `http://<ip>` on the client (`http`, not `https` — a bare IP almost never has a matching TLS cert); `.copy`/`.reveal` still copy (an IP has no Finder target). **git-hash deliberate gap:** a bare commit hash has NO open target — there is no repository-URL context to resolve `a1b2c3d` against (no remote/forge known to the client), so every intent keeps copy. Recording it honestly rather than fabricating a forge guess (which would open the WRONG URL for any non-GitHub remote). Revisit only if a per-pane git-remote origin becomes available to template a commit URL. → [ui-shell Batch-4 LOW]

## E11 open quickly + per-item actions (2026-06-27) — epic E11, plan in [ui-shell/plans/E11.md](ui-shell/plans/E11.md)
- 🚫 **E11 SCOPE CUT: the SSH filter pill is a DELIBERATE PRODUCT CUT, not a missing feature — there is no `ssh` case on the enum, so nothing can route to a dead source.** A reference Open-Quickly design ships EIGHT filter pills (`All / Opened / Recent / Folders / SSH / Agents / Current / Recipes`) and `ES-E11-1` names SSH explicitly; slopdesk overrides both per the standing user reduction (2026-06-26: drop the SSH filter as out of scope). The SSH pill is dropped at the SOURCE — `OpenQuicklyFilter` has no `.ssh` case — so there is **no `~/.ssh/config` parse (client or host), no `⌘S` picker-filter chord, and no "SSH host" row in the Actions-popover table**. The honesty discipline (no dead/half pill, per E8/E10/E12/E15/E17) is satisfied structurally: a removed enum case cannot render a pill that does nothing. The shipped pill ring is **All / Opened / Recent / Folders / Agents / Current** (`OpenQuicklyFilter.pickerPills`, pinned by `OpenQuicklyModelTests`). → [ui-shell/plans/E11-carryovers.md, ui-shell/plans/E11.md ES-E11-1]
- ⏸️ **E11 DEFERRAL: the Recipes pill is OMITTED until E16 (no backing recipe store exists yet) — a one-line code note marks the re-add site.** Recipes ships in **E16** (later in the topo order E11 → E14 → E18 → E19 → E13 → E16); surfacing a Recipes pill now would be a 100%-dead pill (no `RecipeStore`), violating the honesty discipline. So `OpenQuicklyFilter` has no `.recipes` case and the picker ring omits it; a `// Recipes pill: added in E16 once the recipe store exists` note sits at the `pickerPills` array so the re-add point is explicit, not an accident. `ES-E11`'s Recipes coverage moves wholesale to E16. (Same reduction rationale tracks the standing "deferred: populate Recipes" task.) → [ui-shell/plans/E11-carryovers.md, ui-shell/plans/E11.md ES-E11-1]
- ✅ **E11 ARCHITECTURE: Open-Quickly and Jump-To are unified as ONE picker opened to different default pills — adopt carry-over option (a), FOLD the E10 Jump-To panel into the new Open-Quickly picker; `JumpToView.swift` is DELETED.** `⌘J` (Jump-To) and `⌘⇧O` (Open Quickly) are designed as the same multi-source switcher pre-selected to the **Current** vs **All** pill, so a single unified surface is ONE view, not two. The E10 standalone `JumpToView` mount is removed and replaced by `OpenQuicklyView` (ClientUI); a new pure `OpenQuicklyModel` (`WorkspaceCore`) owns the pill taxonomy (`OpenQuicklyFilter` all/opened/recent/folders/agents/current — DISTINCT from the `⌘⇧P` palette's `QueryFilter`, which is unchanged and NOT reused for the pills). The E10 **`JumpToModel` is reused VERBATIM as the Current filter's data source** — its `JumpToItem`/`filtered`/`itemKind` are untouched and its headless `JumpToModelTests` stay green (regression guard for the fold). `⌘J` re-points to `overlay.toggleOpenQuickly(filter: .current)` and `⌘⇧O` to `.all`; the dead `OverlayCoordinator.jumpToVisible` flag + `PaletteMode.openQuickly`/`multiSource` multi-source palette path are removed. The Jump-To link-actuation logic (`actuate`/`rowActions`/pasteboard) is EXTRACTED to a reusable `LinkActionActuator` so Current rows + File/Folder rows share ONE actuator (no regression to `LinkActionPolicy`/`TerminalContextMenu` routing; pinned by `LinkActionActuatorTests`). → [ui-shell/plans/E11.md "Architecture decision"]
- ✅ **E11 NO WIRE / golden ZERO-DIFF: every Open-Quickly source is client-side or reuses an EXISTING verb — `docs/20-wire-protocol.md` is unchanged and `golden_vectors.json` is byte-identical.** The six filters source entirely from seams that already exist: **Opened** = `WorkspaceStore.tree.sessions[].tabs[].root.allPaneIDs()` (vertical-rail only, no horizontal tab-bar concept); **Recent** = `WorkspaceStore.recentlyClosedTabs` LIFO; **Current** = the E10 `JumpToModel`; **Agents** = E4's EXISTING `MetadataClient.listAgentSessions(project:)` (verb 8, Claude-only — `OpenQuicklyModel.agentItems` drops every `agentKind != .claude`, the standing exclusion; iOS sources it host-served too); the Actions popover's **Reveal/Open** reuse E10's EXISTING host `MetadataVerb.openPath = 9` / `revealPath = 10` (status-byte-only, not an exfil vector), Copy actions = client pasteboard, Change-Directory-Here = verbatim UTF-8 `cd <quoted>\n` into the PTY (cd to the PARENT when the target is a file, folding E10's polish), Re-Run = the existing verbatim re-run path. No new message type, no float/codec/controller code — `golden-check.sh` stays zero-diff (verified: empty `git status` on `golden/`, `Sources/slopdesk-corevectors/`, `docs/20-wire-protocol.md`). → [ui-shell/plans/E11.md "Flags", E11-carryovers.md TRAPS]
- ✅ **E11 NET-NEW ENGINE: the Folders frecency database is CLIENT-SIDE, in-process, and persisted to a schema-versioned JSON sidecar — no wire, no host RPC.** "Folders" ranks visited working directories by frecency (`frequency × recency`). The cwds are ALREADY client-observable via OSC 7 → `PaneSpec.lastKnownCwd` (E3), so no socket is added: `WorkspaceStore.setLastKnownCwd(_:for:)` fires a new injected `onCwdVisited: ((String) -> Void)?` closure (keeping the store SwiftUI-/store-agnostic — a closure, not a direct dependency) which the app routes to `FolderFrecencyStore.record(cwd:)`. The scorer (`FolderFrecency`, pure + headless) uses **integer bucket weights × an Int frequency** — no FMA, no bare `</>` on a NaN-capable float; the one `Double` (age-in-seconds) is finiteness-guarded then reduced to clamped whole `Int` seconds so a corrupt/non-finite date scores as ancient and can never trap nor out-rank a real entry (CLAUDE.md §2/§3). The store is **bounded + validate-then-store** (a `maxEntries` cap evicts the least-frecent; a `maxPathLength` cap + empty/whitespace reject drop pathological cwds; no force-unwrap) and **schema-versioned with decode-fail-to-default** (a missing/corrupt/version-mismatched `folders-frecency.json` falls back to empty — single-user no-backcompat, no migration). Empty until a cwd is visited → honest "No folders yet" empty-state, never a dead pill. Pinned by `FolderFrecencyTests` (ordering, caps, record/forget, round-trip, decode-fail) + `CwdVisitHookStoreTests`. → [ui-shell/plans/E11.md ES-E11-4, E11-carryovers.md "The ONE net-new engine"]
- ✅ **E11 CHORD SCOPING: only `⌘⇧O` (open All) and `⌘J` (open Current) are GLOBAL; every per-filter / quick-pick / cycle / Actions chord is PICKER-LOCAL, handled by the panel's own key handler and NEVER registered in `WorkspaceBindingRegistry`.** The pill chords `⌘0`/`⌘W`/`⌘R`/`⌘Z`/`⌘G`/`⌘J`, the `⌘1–9` direct quick-pick, `Tab`/`⇧Tab` pill cycling, and `⌘K` (Actions popover) switch state only WHILE the picker is open. `WorkspaceBindingRouting` gains an `openQuickly` toggle in the `toggles` bundle (alongside `jumpTo`); `case .openQuickly` fires `toggles.openQuickly?()` (→ `.all`) and `case .jumpTo` still fires `toggles.jumpTo?()` but the app now binds THAT to "open OpenQuickly at `.current`". `⌘⇧O` was the free E1 stub; `⌘J` is reused from E10 (not double-bound). `OpenQuicklyModel.quickPickIndex`/`nextFilter`/`prevFilter` are the pure, unit-pinned index/cycle maps the picker-local handlers call. → [ui-shell/plans/E11.md ES-E11-1..3, E11-carryovers.md TRAPS]
- ✅ **E11 REVIEW FIX — "not registered globally" is NOT enough; the dispatcher must MODAL-YIELD the keyboard while the picker is up.** The original chord-scoping rationale ("registering them globally would shadow the app-global `⌘W` / `⌘G` …") was backwards: `⌘W`/`⌘G`/`⌘0`/`⌘1–9`/`⌘J` are ALREADY globally bound (`closePane`/`findNext`/`resetFontSize`/`selectTab`/`jumpTo`), and the app-level `NSEvent.addLocalMonitorForEvents(.keyDown)` in `WorkspaceKeyDispatcher` PREEMPTS the responder chain — so it resolved + SWALLOWED those chords BEFORE `OpenQuicklyView.onKeyPress` ran. Result: with the picker open, `⌘1–9` switched the BACKGROUND tab (never the ES-E11-3 quick-pick), `⌘W` DESTRUCTIVELY closed the focused pane behind the picker, `⌘0`/`⌘G`/`⌘J` reset font / found-next / toggled it shut. Fix: thread an `isOverlayCapturingKeys: () -> Bool` predicate into the dispatcher (the app wires it to `OverlayCoordinator.openQuicklyVisible`); `handle(_:)` returns the event UNCHANGED at the top while it is `true`, so the picker owns the whole keyboard like a modal sheet (Esc / scrim-tap close it; `⌘⇧O`/`⌘J` stay global only while the picker is HIDDEN). At-rest behaviour is byte-identical (default `{ false }`). Pinned by `DispatcherOverlayYieldTests` (picker-visible `⌘W`/`⌘2` pass through + do NOT mutate the tree; the picker-hidden control still swallows + dispatches them). → [E11 confirmed-high review findings]
- ✅ **E11 REVIEW FIX — the per-row `⌘K` Actions table now matches the reference design 1:1 per item type (Recent reopen is index-addressed; Command re-runs; Pane closes; iOS gets a tap fallback).** Four confirmed-medium picker findings, fixed in one pass: **(1) Recent rows reopened the WRONG tab** — every Recent row's `↩` and "Reopen Tab" action called `reopenLastClosedPane()`, which `popLast()`s the LIFO top regardless of which row fired, so picking row 2/3 reopened the newest tab. Fixed by a new index-addressed `WorkspaceStore.reopenClosedTab(at lifoIndex:)` (removes `recentlyClosedTabs[count-1-lifoIndex]`, bounds-checked → out-of-range is a `nil` no-op, never a trap; re-inserts via the SAME `WorkspaceTreeOps.insertTab` + focus path; `reopenLastClosedPane()` now delegates to `at: 0`). Both the `↩` `.reopenRecentTab(index:)` act and the `⌘K` "Reopen Tab" action carry the row's LIFO index, so row N reopens tab N. Pinned by `ReopenClosedTabTreeTests.testReopenClosedTabAtIndexRestoresThatTabNotTheNewest` (revert-to-confirm-fail vs `popLast`). **(2) Command (Current) `⌘K` actions were wrong** — every Current row (incl. `.command`) returned the Jump-To "Jump to + Copy" table; now a `.command` row offers "Re-Run in Current Pane" (the verbatim `BlockReRunEncoder` path via a new `WorkspaceStore.reRunCommandInActivePane(_:)` — strip trailing CR/LF + one `0x0A`, never `SendKeysParser`) + "Copy Command". Prompt/path/url/file rows keep the shared Jump-To table. Pinned by `WB3BlockRoutingDispatchTests.testReRunCommandInActivePaneSendsVerbatimBytes`. **(3) Pane (Opened) `⌘K` actions omitted Close + duplicated Switch** — the table now drops the redundant "Switch to Pane" (`↩` already switches) and adds "Close Pane" routing through `requestClosePaneTree(_:)` (the busy-shell/close-confirm path, so a dirty pane still prompts), keeping Reveal/Copy CWD. **(4) iOS had no touch fallback for `⌘K`/`⌘1–9`** — each row now carries a trailing ellipsis (`ellipsis.circle`) Button under `#if os(iOS)` that selects the row then opens its Actions popover; macOS is unchanged (keeps the `⌘K` chord, no button). **Two deliberate N/A deferrals, pinned here not shipped as dead rows:** **"Re-Run in New Tab"** (a third Command-table action in the reference design) is OMITTED — there is no store hook to defer verbatim bytes into a freshly-materialized pane's PTY after its launch grace (`deferInheritedCwd` is `cd`-only + private), so a faithful new-tab re-run needs a new timing-dependent seam; disproportionate for this fix, deferred. **"Move Tab to New Window"** (a second Tab-table action in the reference design) is N/A in slopdesk's single-window vertical-rail model (one macOS window hosts the whole `TreeWorkspace`; there is no multi-window tab-tear-off). No wire change (golden zero-diff): reuse-only — `reopenClosedTab`/`reRunCommandInActivePane`/`requestClosePaneTree` are client-side store ops, Copy = client pasteboard, Reveal = the existing host verb 10. → [E11 confirmed-medium review findings]

## E14 progress + notifications + privilege parity (2026-06-28) — epic E14, plan in [ui-shell/plans/E14.md](ui-shell/plans/E14.md)
- ✅ **WIRE EXTENSION (golden corpus touched): a new CONTROL type 32 `progress(state:percent:)` (host → client) carries the OSC 9;4 taskbar-progress badge — it CANNOT ride the VT stream (WI-1/K1).** slopdesk surfaces an iTerm2/ConEmu `ESC]9;4;<state>[;<pct>]` taskbar-progress sequence as a per-pane rail-row spinner / determinate badge. That badge is APP CHROME on the vertical rail row, not terminal grid content — the client never renders the sequence as bytes — so it needs a host→client CONTROL message, not a passthrough of the VT bytes. It also must NOT alias onto `notification` (25): the host's OSC-9 path already DROPPED the `9;4` subtype precisely because surfacing `"4;1;50"` as a desktop alert floods the user; K1 turns that drop into a parse→emit. **Design:** new pure `ProgressState` (`0` clear / `1` in-progress / `2` error / `3` indeterminate) + `ProgressOSCParser.parse` (validates the `4;` prefix + state digit, CLAMPS percent to `0…100` with ordered `min`/`max`, DROPS any malformed shape — unknown state, non-integer percent, bare `9;4`, empty) in `SlopDeskProtocol`, shared host+client. `WireMessage.progress(state: UInt8, percent: UInt8)` carries the RAW state byte on a flat 2-byte body `[UInt8 state][UInt8 percent]` (no BE for single bytes) so the codec is a faithful round-trip and the golden vector is stable; the CLIENT re-validates via `ProgressState(wire:)` and DROPS an unknown discriminant (the `metadataResponse`/`claudeStatus` forward-tolerant idiom). A short body decodes to `truncated` (validate-then-drop, never an over-read); trailing bytes are ignored like the other fixed-field decoders. `wireByteCount == 4 + 1 + 2` and encode/decode/round-trip/short-drop/clamp pinned by `WireMessageProgressRoundTripTests` + `ProgressStateTests`; `HostOutputSnifferTests` pins that `ESC]9;4;1;40 BEL` → `.progress(1,40)` (NOT `.notification`) while a free-text `ESC]9;Build done BEL` stays a byte-identical `.notification` (the free-text OSC-9 path is unchanged). Corevectors emits four `progress` keys (`00000003200128` / `…0300` / `…0250` / `…0000`), hand-merged into `golden/golden_vectors.json` so the 13 XCTest-frozen keys survive (`golden-check.sh` zero-diff); the frozen `hostOutputSniffer` `osc9ProgressIgnored` case is renamed `osc9Progress` and now expects the emitted `.progress` frame. Additive within wire version 1 (host accepts only v1, no negotiation) → **host + client redeploy together**; an older peer DROPS type 32 cleanly (`unknownMessageType`). The next free host→client CONTROL byte advances 32 → 33. → [ui-shell/plans/E14.md WI-1]
- 🚫 **CEILING (states 4/5 are NOT a progress wire state — deliberate, documented, not faked).** OSC 9;4 defines two further states the K1 wire deliberately does NOT carry: state `4` (paused/warning) is IGNORED (there is no determinate-paused render surface to honor it honestly), and state `5` (`9;4;5;<exit>[;watch]`, "finished + exit") maps onto the EXISTING `commandStatus(.idle(exitCode:))` path (OSC-133-D) rather than a new `ProgressState` case — a finished command is already an idle-with-exit signal, so a second representation would be redundant + risk a split-brain badge. The `watch` finish suffix on state 5 (the `slopdesk watch` completion source) is **E20 territory** (ES-E20-2): WI-1 parses/clamps the state but ships NO `watch` source, so there is no dead watch path. `ProgressState` therefore has exactly the four cases `clear`/`inProgress`/`error`/`indeterminate`; `ProgressState(wire:)` returns `nil` for 4/5/255 so a future-protocol byte is dropped, never faked. → [ui-shell/plans/E14.md WI-1, scope exclusions]
- ✅ **K2 auto-progress is a PURE host-side prefix matcher wired at the segmenter's C / D marks, resolved through an env bridge (host/client split made faithful).** A shell-integration convention auto-wraps a built-in list of slow commands to emit an indeterminate OSC-9;4 spinner while they run. SlopDesk implements this directly, without a second engine: the new pure `AutoProgressMatcher` (`Sources/SlopDeskHost/AutoProgressMatcher.swift`) does a WHITESPACE-DELIMITED, CASE-SENSITIVE, TOKEN-wise PREFIX match (`git push` matches `git push origin main`, NOT `git status`; `curl` matches `curl …`, NOT `curlie`); an EMPTY prefix list disables auto-progress entirely (clearing the field disables it), and an unmatched command emits NOTHING. The matcher is invoked from the EXISTING `CommandBlockSegmenter` (the OSC-133 tap) at the `C` mark — on a match it queues a SYNTHETIC `.progress(state: 3, percent: 0)` (indeterminate spinner); the matching `.progress(state: 0, percent: 0)` (clear) is queued when the block closes at `D` (or an interrupted re-prompt). The synthetic frames are drained by `CommandBlockTracker.ingest` and ride the SAME CONTROL FIFO as the type-28 block metadata. **Double-driving guard:** a per-block `sawRealProgress` flag is set the moment the PROGRAM emits its OWN OSC 9;4 (which the live `HostOutputSniffer` already turns into the REAL type-32 `.progress` — the segmenter only OBSERVES, it never emits the real one); a real 9;4 BEFORE the `C` decision suppresses the synthetic spinner outright, and a real 9;4 AFTER `C` suppresses the synthetic CLEAR (the program owns the lifecycle). The whole feature is OPT-IN — `CommandBlockSegmenter(autoProgressPrefixes:)` defaults to `[]`, so the segmenter/tracker stay byte-identical until the live owner injects a list. **Host/client split (closest-faithful):** the configurable list lives as the CLIENT setting `SettingsKey.autoProgressCommands` (`[String]`, default the built-in list, Settings → Advanced) — the EDIT/DISPLAY surface; the HOST resolves its working copy at ONE shared site (`HostEnvironment.autoProgressPrefixes()`) from `SLOPDESK_AUTO_PROGRESS_COMMANDS` (NEWLINE-separated entries; UNSET ⇒ built-in, SET-but-EMPTY ⇒ disabled), set IDENTICALLY host+client exactly like `SLOPDESK_FEC_M`. A live client edit therefore re-drives the host matcher only on the NEXT host launch (the env is read at start), not instantly — the remote-architecture equivalent of an in-process setting. **Duplication note:** the built-in list is duplicated (host `AutoProgressMatcher.builtInPrefixes` for ENFORCEMENT, client `SettingsKey.autoProgressCommandsBuiltIn` for DISPLAY) because `SlopDeskWorkspaceCore` cannot import `SlopDeskHost`; the two literals are kept in sync. Pinned by `AutoProgressMatcherTests` (matcher truth table + env resolution + segmenter C→spinner/D→clear + real-9;4 suppression, revert-to-confirm-fail). → [ui-shell/plans/E14.md WI-3]
- ✅ **K5/K8 macOS Dock tile is a PURE decision (`DockTintPolicy`) + a macOS-only AppKit actuator (`DockProgressController`); the dock-CLICK uses the closest-faithful `didBecomeActive`-while-tinted hook because SwiftUI owns `applicationShouldHandleReopen`.** The Dock icon animates during OSC 9;4 progress and tints red on error, and clicking the tinted icon jumps to the next failing tab + clears the tint. SlopDesk splits this the house way: the whole decision is the PURE `DockTintPolicy` (`Sources/SlopDeskWorkspaceCore/Workspace/Store/DockTintPolicy.swift`) — `tint(forRollup:)` (the plan-pinned `.error` → red) plus `resolve(progressRollup:anyFailure:animateProgressEnabled:errorBadgeEnabled:)` → a `DockTileModel{tint, animatesProgress, determinateFraction}` that folds the two toggles + the non-zero-exit signal (an ordered-`min`/`max` clamp on `percent/100`, no fused multiply). The store exposes ONE `@Observable`-derived `WorkspaceStore.dockTileModel` (over `rollupProgressAcrossSessions()` + `anyFailureCompletion`, i.e. the WHOLE tree — the Dock is process-global), so a progress/completion EDGE re-renders the app shell, which re-applies the tile. The macOS-only `DockProgressController` (`Sources/SlopDeskClientUI/App/DockProgressController.swift`, `#if os(macOS)`) owns ONLY the `NSDockTile` drawing (app icon + animate-on-progress bar / sweep + red wash) and the K8 `NSApp.requestUserAttention(.informationalRequest)` bounce; **ES-E14-3: never instantiate an `NSDockTile` in a test** — `DockTintPolicyTests` pins the pure decision, the drawing is Phase-3 GUI-verified only. **K8 bounce drives off the NOTIFIER, not the bell** (carryover): wired to `CommandCompletionNotifier.bounceDock`, fired on a DELIVERED banner while the app is backgrounded, gated by the "Bounce Dock Icon" toggle AT the actuation seam (the pure notifier stays toggle-agnostic). **Dock-click → next failing tab (closest-faithful):** the precise per-click hook is `NSApplicationDelegate.applicationShouldHandleReopen`, which the SwiftUI `App` owns and does not surface; rather than seize the app delegate, the controller treats "the app became active WHILE the tile is red" (`NSApplication.didBecomeActiveNotification` + `lastModel.tint == .error`) as the click, calling `WorkspaceStore.revealNextErrorPane()` — which cycles to the next failing pane (error progress OR `.failure` completion badge), reveals it, and ACKNOWLEDGES it (clears its error signals) so repeated returns step through every failing tab and the tint clears once the last is visited. **Carryover trap (no stuck red tile):** the tile is process-global mutable state, so a last-session-end edge resolves to `DockTileModel.inert` → the controller CLEARS, and the app also clears on `willTerminate`. **Two new keys** (`dockIconAnimateProgress` default OFF, `dockIconErrorBadge` default ON) surfaced under **Appearance → Dock Icon** per the spec (M2 — the `AppearanceSettingsTab` group binds `@Default(.dockIconAnimateProgress)` "Animate Icon on Progress" / `@Default(.dockIconErrorBadge)` "Red Icon on Error", wrapped `#if os(macOS)`; the searchable All-Settings rows are `hasDedicatedTab`→`appearance` so a search JUMPS to that group rather than rendering a duplicate inline control) — macOS-only NSDockTile behaviour; the keys compile + round-trip on iOS (inert there, no Dock), and `DockProgressController` is the only macOS-gated consumer. → [ui-shell/plans/E14.md WI-5]
- ✅ **K6 OSC 99 (kitty desktop-notification protocol) is a BOUNDED, validate-then-drop SUBSET parsed host-side onto the EXISTING `notification` (type 25) — NO new wire.** Kitty's `ESC ] 99 ; <metadata> ; <payload> ST` notification escape is honoured. SlopDesk adds a `case "99":` arm to `HostOutputSniffer.finishOSC` (alongside OSC 9 / 777) that maps the parse onto `WireMessage.notification(title:body:)` — the macOS/iOS banner surface is the SAME `UNUserNotificationCenter` path as OSC 9/777, so a second wire message would be redundant. **Implemented subset:** the title/body payload, base64 decoding (`e=1` → `Data(base64Encoded:)` → UTF-8, drop on failure), and the `i=<id>` group / `d=0` chunked-continuation assembly (the `replace-by-id`/multi-chunk minimum) — a `d=0` chunk is BUFFERED in a bounded `kittyAssembly[id]` slot and only FINALIZED + emitted at the `d=1` (default) chunk. **Title/body mapping (closest-faithful):** kitty's default payload type is `p=title`; a TITLE-only notification is FOLDED into the `.notification` body (empty title → the client's pane-title fallback, exactly like the OSC-9 empty-title form), while a `p=body` chunk that supplies a distinct body keeps both fields. So the canonical `ESC]99;;Build finished ST` surfaces as `.notification(title:"", body:"Build finished")`. **Bounded validate-then-drop (hostile-input discipline):** each chunk is capped at the shared `notifyOscCap` (1024 B) BEFORE any parse; the in-flight assembly is capped at `kittyAssemblyMax` (8 distinct ids) and `kittyAssemblyCap` (4096 accumulated chars) so a `d=0` stream that never finishes — or opens many ids — can never grow unbounded; a missing metadata/payload `;`, an unknown encoding `e` (only 0/1), an unsupported payload type `p`, bad base64, or non-UTF-8 bytes all DROP the chunk (no force-unwrap, no trap). The assembly mutates only at `finishOSC` (sequence completion), exactly like the `lastTitle` dedup, so the chunk-invariance oracle (byte-split == whole) still holds. **CEILING (documented, not faked):** the broader kitty surface — urgency levels (`u`), the capability-query reply (`p=?`), action buttons (`buttons`), icons (`icon`/`g`), and multi-DATAGRAM reassembly — is deliberately NOT implemented; an unsupported `p` (incl. the capability query) is DROPPED, never ANSWERED, so there is no dead capability-query path (honesty discipline). Pinned by `OSC99ParseTests` (plain/title/body payload → body fold, base64 decode, chunked title+body assembly, malformed/oversized/capability-query/unknown-encoding dropped, OSC 9/777/title paths untouched, DCS-embedded anti-spoof, chunk-boundary invariance — every assertion reverts-to-confirm-fail on the un-`case "99"`'d sniffer). → [ui-shell/plans/E14.md WI-6]
- ✅ **K11/K12 privilege surface: Title — Shell Controlled + Clipboard — Shell Controlled ACTUATE; Title Report is a documented CEILING that ships OFF, not a dead control.** slopdesk's privilege toggles (Settings → Advanced) gate what a remote OSC sequence may do client-side. Three new fire-time `Defaults.Keys` flags (golden-safe, like the E8 clipboard keys): `titleShellControlled` (`controls.titleShellControlled`, default **ON**), `titleReport` (`controls.titleReport`, default **OFF**), `clipboardShellControlled` (`controls.clipboardShellControlled`, default **ON**). **(1) Title — Shell Controlled ACTUATES:** `TerminalViewModel.handle(.title)` now gates the OSC 0/2 title update behind `SettingsKey.titleShellControlledEnabled` — OFF DROPS the update so a remote program cannot rewrite the tab/window title (the same `!text.isEmpty` empty-redraw guard is kept). **(2) Clipboard — Shell Controlled ACTUATES as the OSC-52 master:** `TerminalControls.from(defaults:)` (the ONE read site feeding the libghostty `clipboard-read/write` config lines) resolves BOTH directions to `ClipboardAccess.deny` when the master is OFF, AHEAD of the per-direction Ask/Allow/Deny gate — so the whole OSC-52 path is denied with one switch (the per-direction E8 pickers are DISABLED in the UI while the master is off). The existing `clipboardRead`/`clipboardWrite` (E8) are reused verbatim — the confirm sheet is NOT reimplemented. **(3) Title Report is a CEILING (honesty discipline):** title read-back is `OSC 21` / XTWINOPS, which the pinned libghostty fork answers ITSELF — the `TerminalSurface` seam (`feed`/`setSize`/`handleInput`/`onWrite`) exposes NO title-query API and `TerminalConfigBuilder` emits no title-report key, so there is no enable/disable hook to wire. Rather than ship a dead control, `titleReport` persists/surfaces (forward-compatible: `titleReportEnabled` is read fire-time) but does NOT yet actuate, ships **OFF** (the conservative exfiltration-safe default — a program that can both set and read the title can leak data through a pane), and the All-Settings / navigator rows are relabelled "Persisted but not yet enforced — the terminal renderer answers this query itself." Revisit if/when the fork exposes an XTWINOPS gate. **System Permission status row (`PermissionStatus`):** the pure, headless `PermissionStatus.dot(forAuthorization:)` maps a `UNAuthorizationStatus.rawValue` → green (authorized/provisional/ephemeral = `2`/`3`/`4`) / red (denied = `1`) / amber (notDetermined `0` + ANY unknown future value — the conservative "not proven allowed", never a false green). It is framework-free so `PermissionStatusTests` pins it WITHOUT instantiating `UNUserNotificationCenter` (which traps without a bundle — the same hang/crash-safety boundary as the video sessions). The `NotificationPermissionRow` view (top of Settings → Shell → Notification) queries `getNotificationSettings`, renders the dot + an **Open System Settings** button: macOS deep-links to `x-apple.systempreferences:com.apple.preference.notifications` (`#if os(macOS)`); **iOS caveat** — iOS CANNOT deep-link to the per-app OS notification pane, so the button opens the app's OWN settings via `UIApplication.openSettingsURLString` (`#if os(iOS)`). The full NOTIFICATION group (the master + per-event toggles + the Notify-While-Foreground tri-state picker + the macOS-only Bounce Dock Icon) + SOUND + CODE AGENT groups are now surfaced in the Shell navigator (the WI-4 `NotificationPolicy` engine backs them — the old "deferred subset" note is removed); the title gates + OSC-52 master + read/write pickers home under Advanced → Privileges per the spec. Pinned by `PermissionStatusTests` + `SettingsKeyTests` (privilege defaults/strings + the clipboard-master `from()` gate, revert-to-confirm-fail) + the `AllSettingsCatalog` coverage test. → [ui-shell/plans/E14.md WI-7]
- ✅ **K13 IPC guards on the agent-control ctl socket are PURE host-side gates on the existing NDJSON socket — no new socket, no tokens, no crypto.** A local-process control surface is the natural IPC threat model here; slopdesk's nearest equivalent is the opt-in `SLOPDESK_AGENT_CONTROL` ctl socket (`AgentControlListener`), so K13 maps the toggles onto IT (the WireGuard mesh remains the security boundary — there is no app-layer auth, by design). `AgentControlHandler.dispatch` now gates the MUTATING verbs (`write`/`run`/`spawn`/`kill`/`resize`, the "send keys" equivalents) behind `IPCGuards.allowSendKeys` (default OFF → `{"ok":false,"error":"ipc send-keys disabled"}`), and a mutating verb whose TARGET pane runs a SENSITIVE foreground process (`ssh`/`sudo`/`su`/`login`/`doas`/`passwd`/`gpg`/`security`/`sshpass`/`ssh-agent`/`ssh-add` — the bounded `SensitiveSessionPolicy.sensitiveBasenames`, case-sensitive basename match, since the host has no broader sensitive-session detector) behind `allowSensitiveSessions` (default OFF → `"ipc sensitive-session blocked: <name>"`). The READ-ONLY verbs (`list-panes`/`read`/`wait`/`report`, plus the acceptor-intercepted `subscribe` output stream) are ALWAYS allowed. The guard fires at the TOP of `dispatch` BEFORE any pane lookup / side effect, so a refused verb never touches the PTY (and `spawn` — which names no target pane — is covered by the send-keys gate alone, so it never forks a shell when disabled). **Resolved from env at the dispatch site:** `IPCGuards.resolved()` (the `dispatch` default arg, evaluated per call) reads `HostEnvironment.ipcAllowSendKeys()` / `ipcAllowSensitiveSessions()` — DEFAULT-OFF (`env[key] == "1"`, same idiom as `agentControlEnabled`), `SLOPDESK_IPC_ALLOW_SEND_KEYS` / `SLOPDESK_IPC_ALLOW_SENSITIVE`, through the same `EnvConfig` overlay as K2 so a GUI toggle reaches the gate. The sensitive-session foreground name is resolved via an INJECTED seam (`foregroundName:` default `probeForegroundName` → `PTYForegroundProbe.foregroundName(masterFD:)`), so `IPCGuardTests` exercises the gate WITHOUT a live PTY (hang-safety). **Closest-faithful caveat:** the two client toggles (`SettingsKey.ipcAllowSendKeys` / `ipcAllowSensitiveSessions`, both default OFF, Settings → Advanced) are the EDIT/DISPLAY surface; ENFORCEMENT is host-side, so a live client edit re-drives the host only on the NEXT host launch via the env bridge (set identically host+client, same discipline as K2 / `SLOPDESK_FEC_M`). Pinned by `IPCGuardTests` (send-keys refuse/allow per verb, sensitive refuse/allow with an injected fg, read-only always-allowed, `SensitiveSessionPolicy` truth table incl. full-path-basename reduction + case-sensitivity, env default-OFF idiom — every assertion reverts-to-confirm-fail) + `SettingsKeyTests` (defaults/strings) + the `AllSettingsCatalog` coverage test. → [ui-shell/plans/E14.md WI-8]

## E13 agent integration UI (Claude Code) (2026-06-28) — epic E13, plan in [ui-shell/plans/E13.md](ui-shell/plans/E13.md)
- ✅ **E13 WI-1 install/uninstall/status are THREE new `MetadataVerb` bytes on the EXISTING E4 RPC (no new wire type, envelope byte-identical) — the second family of side-effecting verbs after E10's 9/10.** The Agents settings card's Install / Uninstall / Status need a LIVE wire trigger (the user clicks Install and expects an immediate host file write + a status flip), so they ride the existing `metadataRequest`(16)/`metadataResponse`(30) pair via `MetadataVerb.installAgentHooks = 11` / `.uninstallAgentHooks = 12` / `.agentHookStatus = 13`. 11/12 are SIDE-EFFECTING (write the hook script + merge into / strip from `~/.claude/settings.json` via the EXISTING pure `AgentInstaller`) and reply with an EMPTY payload + a status (`ok`/`error`); 13 is a PURE READ of the install marker that replies `ok` + a **1-byte** flag (`1` installed / `0` not). All three carry an EMPTY request payload and are **host-global** (install/uninstall act on the host's single settings file regardless of which pane's mux channel carried the request — the card routes through the FIRST connected pane's `MetadataClient`). The verb is already an opaque forward-tolerant `UInt8` (an unknown verb → `unsupportedVerb`, never a trap), so there is NO new message type and NO envelope-codec change; the golden corpus gains TWO representative samples (an `installAgentHooks` request, verb 11, requestID `0x0B0C0D0E`, empty payload — 12/13 are byte-identical save the verb byte; and an `agentHookStatus` response, status `ok` + 1-byte `[0x01]` payload — the only agent-hooks reply that carries a payload), hand-merged so the 13 XCTest-pinned frozen keys survive (`golden-check.sh` zero-diff). → [ui-shell/plans/E13.md WI-1]
- ✅ **E13 WI-1 the host routes 11/12/13 to a thin `#if os(macOS)` `HostAgentActionPerformer` (twin of `HostPathActionPerformer`) inside `serveMetadata` BEFORE the read-only `MetadataResponseBuilder`, which never sees them.** The performer wraps the EXISTING `AgentInstaller.install`/`uninstall` (a thrown disk/permission failure → `.error`, never a trap) and a NEW pure `AgentInstaller.isInstalled(settingsPath:fileManager:)` (the only genuine logic add to that file — reads the settings tolerantly via the existing `readSettings`, scans every event's entries for our `hookMarker` via `entryIsOurs`, returns `false` on a missing/corrupt/hook-less file). It resolves the target via `defaultSettingsPath()`/`defaultScriptPath()` (honoring `CLAUDE_CONFIG_DIR`) and IGNORES the request payload (host-global, empty by contract). Like `HostPathActionPerformer` it is **compiled + code-reviewed ONLY** — never instantiated in a unit test (it touches the host home settings file on disk; the hang/IO-safety rule). The CLIENT routing (`MetadataClient.installAgentHooks`/`uninstallAgentHooks` → `true` only on `.ok`; `agentHookStatus` → `true`/`false`/`nil`, where `nil` on a non-`ok` / empty-payload / dropped reply lets the card show "Connect a session to manage hooks" rather than a false "Not Installed") is the unit-tested half (`MetadataClientAgentHooksTests`), and the pure install/marker logic is pinned by `AgentInstallerTests` + `AgentInstallerStatusTests`. **Claude Code ONLY** — there is no codex/opencode install path on the wire or in any UI (the carryover Claude-only directive). → [ui-shell/plans/E13.md WI-1]
- ✅ **E13 WI-3 the 7 behaviour toggles split by mechanism, NOT a uniform store: badge×3 are fire-time `Defaults.Keys` (apply LIVE), prevent-sleep + resume-on-recovery are `AgentPreferences` sidecar flags (apply on RECONNECT), notify×2 are the reused E14 keys.** The Agent-Behaviour group is `badge×3` + `notify×2` + `preventSleep` + `resumeOnRecovery`. badge×3 (`agents.badgeWhileProcessing/WhenComplete/WhenAwaitingInput`, default ON) are fire-time flags like notify×2 — they gate which fused tab badge the sidebar SHOWS via the pure `AgentBadgeGates.gated(_:by:)`, applied in `RailRowsBuilder` AFTER the (unchanged, signal-only) `TabBadgeResolver`; `error`/`sudo`/`caffeinate` survive every gate (never agent opt-out chatter). **Prevent-sleep / resume-on-recovery are HOST-LOCAL policies, so they ride the EXISTING `AgentPreferences` sidecar (the `agentDetect`/`agentHooks` precedent), NOT new `SettingsKey` Defaults** — a dual SettingsKey+typed-pref source would diverge, and host flags are typed-prefs→sidecar everywhere else (Video host flags, agentDetect/agentHooks). New `AgentPreferences.preventSleep`/`resumeOnRecovery` (`Bool?`) → `EnvBridge.toEnv` → `SLOPDESK_AGENT_PREVENT_SLEEP` (default-OFF `== "1"`) / `SLOPDESK_AGENT_RESUME_ON_RECOVERY` (default-ON `!= "0"`), read by new `HostEnvironment.agentPreventSleepEnabled`/`agentResumeOnRecoveryEnabled`. So the work item adds 3 SettingsKeys (badge×3) + 2 sidecar fields, NOT 5 SettingsKeys (the deliberate deviation from the literal plan count, to avoid a divergent dual source). **Prevent-sleep actuates host-side WITHOUT a wire verb:** `slopdesk-hostd` reads the gate and, when ON, registers `HostServer.observeAgentStatusForPreventSleep` (a thin public seam over the EXISTING P1 agent-status fan-out) feeding a serialized `PreventSleepDriver` that aggregates `.working` panes and asks the pure `PreventSleepPolicy.shouldAssert(anyAgentWorking:enabled:)` whether the macOS-only `PreventSleepAssertion` (a STRICTLY balanced single `IOPMAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep)`, create⇄release paired, deinit-released — the `EnableSecureEventInput` balance lesson; code-reviewed-only, never test-instantiated) holds. **Resume-on-recovery is a forward flag** — the reader exists + round-trips today; its reconnect-path actuation lands in a later item (honest, like `titleReport`). **Per-pane override + Clear-Badge:** a `WorkspaceStore.paneAgentBadgeOverrides` map (override-else-global via `agentBadgeGates(for:)`, pruned on reconcile) backs the tab context-menu badge toggles, and `clearAgentBadge(_:)` acknowledges a pane (clears the ✓/✗ completion badge + settles a `.done` agent to `.idle`) while leaving a LIVE state (working/awaiting) untouched — NEVER an approval gate (carryover directive 2). The Agent-Behaviour section is greyed until an integration is installed (reads `AgentHooksController.isInstalled`). Pinned by `AgentBadgeGatesTests` (gating matrix), `AgentBadgeStoreTests` (override/clear), `PreventSleepPolicyTests`, `AgentPreferencesSidecarTests` (EnvBridge⇄HostEnvironment round-trip). Claude-only. → [ui-shell/plans/E13.md WI-3]

## E21 remote-window pane as a first-class peer through every clone surface (2026-06-29) — epic E21, plan in [ui-shell/plans/E21.md](ui-shell/plans/E21.md)
- ✅ **E21 framing: AUDIT → FILL-GENUINE-GAPS, not build-from-scratch — a `.remoteGUI` pane (a real host window streamed over the PATH-2 UDP video path) is already a kind-generic peer of a terminal in MOST surfaces; the diff is small + surgical EXCEPT one net-new render piece.** A grep-grounded surface-by-surface audit (picker/connect overlay, Open-Quickly, status bar, sidebar row, drag-drop, zoom, palette switch, read-only) found the picker→`newRemoteWindowTab` path, the `PaneKind` switches (`paneKindLabel`/`PaneChooserRegistry`/`LivePaneSession.make`), `Tab.zoomedPane`, `WorkspaceTreeOps.split`/`toggleFloating`, and `openedItems` ALL already kind-generic / exhaustive over `PaneKind`. **`touchesWire = false`** (no golden change — verified zero-diff), **`touchesIOS = true`** (shared `SlopDeskClientUI` + `SlopDeskWorkspaceCore`; gate runs `scripts/check-ios.sh`). The peer status is regression-pinned by `RemoteGUIFirstClassPeerTests` (Open-Quickly inclusion + differentiation, status-bar label/exit, float toggle/spawn for a `.remoteGUI` active pane, split-with-`.remoteGUI`-sibling, read-only policy, picker→`.remoteGUI` spec). → [ui-shell/plans/E21.md WI-1/WI-8]
- ✅ **E21 WI-8 first-class-peer SWEEP is clean: every `switch` over `PaneKind` is exhaustive (no `default:` arm), and every `== .terminal` guard is a DELIBERATE terminal-only behaviour, not an accidental peer-drop.** The grep sweep (`case .terminal` / `== .terminal` / `default:` over `PaneKind`) found three exhaustive switches that each explicitly handle `.remoteGUI` (`PaneChooserRegistry.option` → "Remote window"/`display`, `LivePaneSession.make` → `makeRemoteGUI`, `StatusBarModel.paneKindLabel` → "remote") and five terminal-only equality guards that are CORRECT exclusions: `PaneSpec.canReceiveText` (only a terminal absorbs a text drop — the WI-7 exclusion), `WorkspaceStore.collectGlobalSearchSources` (only a terminal has scrollback lines — E5 divergence #4/#5), `deferInheritedCwd` (only a terminal can take a `cd`), `WorkspacePersistence.isDefaultTreeShape` (the throwaway-default detector), and `StatusBarModel.exitBadge` (an exit code is terminal-only → `.none` for video). No `default:` arm anywhere is over `PaneKind` (they decode wire bytes / ANSI / CLI args). So a new `PaneKind` case forces a compile error at the switches (the centralization win) and cannot silently vanish from a surface. → [ui-shell/plans/E21.md WI-8]
- ✅ **E21 WI-6 the floating-pane RENDERER landed (`FloatingPaneCard`) — the ONE genuine net-new view of E21; an in-app SwiftUI card, NOT an OS PiP / AppKit child window.** The float DOMAIN (`WorkspaceTreeOps.toggleFloating`/`spawnFloating`/`moveFloating`/`resizeFloating`/`raiseFloating`/`clampFloatingFrame` + the `WorkspaceStore` wrappers + `SplitTreeRenderModel.floatingLeaves`) was already built + unit-tested, but `SplitContainer` called `layout(for:in:)` WITHOUT the `floating:` arg so `floatingLeaves` was always empty and `updateFloatingBounds`/`moveFloating`/`resizeFloating`/`embedFloating`/`closeFloating` had NO view caller — floating was invisible. WI-6 builds `FloatingPaneCard` (a card — radius + `Slate.Line.card` hairline + faint `Slate.State.shadow` — over a grab strip with embed/close controls) hosting the SAME kind-generic `PaneContainer` the tiled `SplitContainer` mounts, so a terminal, a local web pane, AND a `.remoteGUI`/`.systemDialog` video pane all float for free (NO kind branch). `SplitContainer` now feeds `store.floatingPanePairs(for:)` into `layout(…, floating:)`, reports container bounds via `store.updateFloatingBounds(_:)`, and renders `floatingLeaves` as z-ordered cards above the tiled `ZStack`. **One-surface / no-teardown invariant** (the load-bearing rule): each card is keyed `.id(PaneID)` so the hosted surface is never reconstructed across panes, and the drag/resize gestures hold the live frame in `@GestureState` clamped by the SAME `clampFloatingFrame` the commit uses — the store reconciles exactly ONCE on `.onEnded` (never per drag frame), so a floated remote window keeps streaming across float/move/resize/embed. `.remoteGUI` becomes a first-class FLOAT with no video-specific code. (E19 deferred true PiP / per-pane OS window; E21 "floating" is strictly the in-app card.) `Tab.floatingPanes` — schema-reserved-and-empty since docs/42 — is now the LIVE float layer (its stale "always `[]` in the MVP" doc was corrected). → [ui-shell/plans/E21.md WI-6]
- ✅ **E21 WI-3 read-only on a `.remoteGUI` pane is enforced CLIENT-SIDE by NOT FORWARDING video input (`RemotePaneContext.inputEnabled`) — wire-compatible silence, NO VideoControl change, NO golden touch.** The kind-generic `paneReadOnly` set + the `SlateTabRow.readOnly` lock + the read-only pill already rendered for a `.remoteGUI` pane, but the video-input ingress did NOT consult read-only → a "read-only" remote window still accepted mouse/keyboard. Rather than a new over-wire read-only verb, read-only is enforced by SUPPRESSING the client→host input forward: additive `RemotePaneContext.inputEnabled` (default `true`) gates the app-target video client on `isActive && inputEnabled` (a click may still ACTIVATE the workspace pane, but it relays NOTHING to the host and does not raise the host window), and the paste-as-keystrokes sink is cleared (`onKeyInjectorReady` hands `bindKeyInjector` a `nil` sink → `RemoteWindowModel.canPasteKeystrokes == false`, `pasteAsKeystrokes` inert). The policy is resolved at a PURE seam — `RemotePaneContext.videoLeaf(isActive:readOnly:bindKeyInjector:)` — so `GuiLeafView` stays a thin renderer (`readOnly: store.isReadOnly(for: paneID)`), there is NO model→store coupling, and the derivation is unit-testable headlessly (no Metal/VT). The actual CGEvent suppression lives in the app-target `SlopDeskVideoClient` (gated `isActive && inputEnabled`) — compiled + code-reviewed only (hang-safety). Pinned by `ReadOnlyStoreTests` (the `inputEnabled`/`nil`-sink seam derivation) + `RemoteGUIFirstClassPeerTests`. → [ui-shell/plans/E21.md WI-3]
- ✅ **E21 WI-2/4/5 the peer-differentiation surfaces (Open-Quickly row, status bar, sidebar row) read a `.remoteGUI` pane as a WINDOW, purely client-side.** WI-2: `OpenQuicklyModel.paneItem`/`openedItems` thread an optional `paneKind` (read from `spec.kind`) so a video pane's row shows the window glyph (`display`) + a "Window"/"Dialog" badge + a host/window-title subtitle (a real cwd, if present, still wins — the subtitle never silently drops a working directory), while the `Act` stays a plain focus-by-`PaneID` (kind-generic). WI-4: `StatusBarStrip` now MOUNTS in `GuiLeafView` (it previously mounted only in `TerminalLeafView`, so a focused video pane had no status bar) — the existing `StatusBarModel` already labelled `.remoteGUI` "remote" with `exit == .none` + empty cwd. WI-5: `RailRowsBuilder` prefers a host/window-title subtitle over the (nil) cwd for a `.remoteGUI`/`.systemDialog` row (the readOnly lock already rendered kind-generically). Pinned by `OpenQuicklyModelTests`, `StatusBarModelTests`, `RailRowBuilderTests`. → [ui-shell/plans/E21.md WI-2/WI-4/WI-5]
- 🚫 **E21 WI-7 EXCLUSION (deliberate, documented, not a gap): there is NO drop-to-create a remote-window pane — a `.remoteGUI` pane is minted SOLELY by the picker / connect overlay, never by a file/URL/text drop.** `DropAction` carries terminal/web cases only — there is no `.remoteGUI` creator arm in `DropActionResolver`, so no `(zone × content)` cell can spawn a video pane (a streamed host window has no "drop a file to open it" semantics; remote windows come from `WorkspaceStore.newRemoteWindowTab`). Conversely a foreign drop ONTO an already-mounted `.remoteGUI` target self-guards: `PaneDropReceiver` holds a `nil` `terminalModel` for a video pane and every terminal actuator is `terminalModel?.…` optional-chained, so the drop no-ops without a crash, while the store-level split/reorder geometry stays kind-generic (a video pane tiles + splits as a peer once minted). Pinned by `RemoteGUIFirstClassPeerTests` (split-with-video-sibling + foreign-drop-self-guard) + the `DropActionResolver` doc. → [ui-shell/plans/E21.md WI-7]
- ⏸️ **E21 deferred (no inert chrome shipped): per-host badge / multi-host selector in the pickers stays SCHEMA-RESERVED until live multi-host lands.** There is no live multi-host today (`DECISIONS.md` "Coding-workspace redesign" keeps per-session multi-host modelled-but-deferred; the MVP shares the one `AppConnection` to bound blast radius), so E21 ships NO multi-host chrome (no per-host badge, no host selector) — surfacing it now would be a 100%-dead control, violating the honesty discipline. Recorded as a deferred extension point for when multi-host goes live. The optional video-connection status DOT in the rail row (WI-5) is likewise deferred if it risks the gate (the row degrades gracefully to a no-dot title+subtitle). → [ui-shell/plans/E21.md §1, §7]

## Phase-C GUI audit — deliberate non-clones & confirmations (2026-06-29)
> HW/GUI-screenshot pass over the finished E1–E21 ladder. These record the audit findings that are BY DESIGN (so a later pass doesn't re-flag them as gaps) plus the one cosmetic fix shipped.
- ✅ **(C2) The theme default is intentionally OS-ADAPTIVE, NOT a fixed dark default.** A `nil` `ThemeChoice` (the unset / first-run state, ES-E15) resolves to **`monokai-classic-light` in light mode** and the **dark default in dark mode** — the app follows the system appearance until the user pins a theme. This is deliberate (it is why the navigator reads as warm light paper on a light-mode Mac); do NOT "fix" it to a hard dark default. → [E15]
- ✅ **(P5) Navigator `sidebar` fill warmed toward a cream/paper tone (cosmetic, light default only).** The `monokaiProClassicLight` `sidebar` token nudged `0xEDE7E5 → 0xF1EBE8` — brighter + a hair warmer, HUE-PRESERVING (keeps the seed's rose R>G>B ratio, closer to the warm `background`). `sidebar` is its OWN token (the navigator / Settings-sidebar / inspector / agent-history panels), NOT the shared flat `window`/`content`/`card` backdrop, so the nudge does not ripple to the pane/terminal surfaces. The measured `.paper` theme and every dark Monokai filter are left untouched. → `Sources/SlopDeskClientUI/DesignSystem/SlateDesign.swift`
- 🚫 **(D1) The details-Info "Reveal in Finder / Open in VS Code · Cursor · Xcode · Typora" cluster is NOT built — slopdesk is a REMOTE client.** A local file reveal / "open in editor" only makes sense for a local terminal acting on the same machine; slopdesk's files live on the HOST, so a client-side reveal/open would target the wrong (local) machine — there is nothing honest to open. slopdesk keeps **Copy Path** (a host path string is portable + useful), and drops the local reveal/open buttons. → [E9]
- 🚫 **(D2) The details-Git panel is READ-ONLY status by design — Commit / Fork WRITE buttons are intentionally not built.** E9's Git surface reports status (branch / dirty / ahead-behind) only; mutating git state from the client would be a write action on the remote host outside the terminal the user is driving (split-brain with the agent / shell). Git WRITES stay in the terminal pane (the real `git` the user/agent runs), the panel observes. → [E9]
- 🚫 **(D3) The Settings → General "Language" (localization) picker is OUT OF SCOPE.** slopdesk ships a single (English) UI locale; there is no localization layer to switch, so a Language picker would be a dead control. Deliberately not cloned, consistent with the honesty discipline (no inert chrome). → [E7]

## Progress / Tab-Badge cluster (2026-06-29) — Batch-2 audit fixes
- ✅ **The tab-badge gates are now SOURCE-AWARE: the agent ("Agent Behaviour") and command ("TAB BADGE") toggles gate their OWN badge families independently, and program progress has no opt-out.** Gating moved from a post-fuse `AgentBadgeGates.gated(_:by:)` (which saw only the single fused `TabBadgeKind` and so could not tell an AGENT spinner from a PROGRAM busy/OSC 9;4 spinner) to `TabBadgeGating.resolve(...)`, which masks the pure `TabBadgeResolver` INPUTS by source. The agent gates suppress only their own `ClaudeStatus` signal (`working`/`done`/`needsPermission`); the new command gates (`CommandBadgeGates`) suppress only the COMMAND-exit `.success`/`.failure` badge; a program's busy / OSC 9;4 indeterminate spinner and an OSC 9;4;2 progress error are NEVER masked (no opt-out, per `progress-state.md`). "Agent — While Processing" now defaults **OFF** (spec: "Claude Code — While Processing (off by default)"). New client-side fire-time `Defaults.Keys` (golden-safe): `tabBadge.onCommandFinish` / `tabBadge.onCommandFail` / `tabBadge.onCommandAwaitInput` (all default ON), surfaced as a "TAB BADGE" Section under Settings → Shell (directly under NOTIFICATION, matching `notification-setting.png`), distinct from the Agents-tab badge gates; reset by `resetAll()` via `tabReachableDefaultsKeys`. → `AgentBadgeGates.swift`, `SettingsKey.swift`, `RailRowsBuilder.swift`
- ✅ **A command-START edge (OSC 133;C / `.commandStatus(.running)`) clears a STALE completion badge.** `ConnectionViewModel.onCommandStarted` → `WorkspaceStore.handleCommandStarted(id:)` clears `panePendingCompletion[id]` so a busy background pane that previously failed (red error triangle) resolves to the running spinner when a NEW command starts, instead of pinning the prior run's exit badge (the resolver ranks `.failure` above the running spinner). → `WorkspaceStore+Completion.swift`, `ConnectionViewModel.swift`
- ✅ **The determinate "NN%" OSC 9;4 readout is now rendered cross-platform in the per-pane status strip.** `StatusBarStrip` consumes the previously-dead `StatusPresentation.progressPresentation(_:)` so a determinate `9;4;1;NN` state shows a linear bar + "NN%" (and an indeterminate state a compact spinner) on iOS too — not only on the macOS Dock tile. → `StatusBarStrip.swift`
- ⏸️ **DEFERRED CEILING (honest gap, toggle shipped ahead of the signal): the host-side ~1.5s cursor-at-prompt quiescence DETECTOR for "plain command awaiting input" is NOT implemented.** `progress-state.md` (lines 30/35) specifies an `awaitingInput` hand for a plain command stopped at an interactive prompt (`[y/n]`, a password read, "Press ENTER to continue"), detected "after ~1.5 s of cursor-at-prompt with no input; typing clears it". Implementing it requires a NEW host-side PTY-quiescence timer on the hot terminal path with real risk of false positives and timing-dependent tests — out of the conservative low-risk envelope for this batch. The Settings → Shell **"When Command Awaits Input"** toggle (`tabBadge.onCommandAwaitInput`) IS shipped and WIRED into `TabBadgeGating.resolve` (`CommandBadgeGates.whenCommandAwaitsInput`), so when the detector lands it gates the new signal with NO further gating-code change. Today `awaitingInput` therefore remains Claude-agent-only (`ClaudeStatus.needsPermission`). → `AgentBadgeGates.swift` (`TabBadgeGating`), [progress-state.md]

## Sidebar rail + auto-hide cluster (2026-06-29) — Batch-3 audit fixes
- ✅ **The sidebar row-select is FLOAT-AWARE: clicking a floated pane's row in a BACKGROUND tab now stamps that tab's recency, exactly as a tiled-pane row does (E21 F1 class).** `NavigatorColumn.select(_:)` re-derived the owning tab with a hand-rolled `tab.root.allPaneIDs().contains(paneID)` scan that sees the SPLIT TREE only, so a floated pane (which still has a rail row — `RailRowsBuilder` enumerates the float-aware `tab.allPaneIDs()`) never matched, the `selectTab(index)` call was skipped, and the E6 WI-3 recency stamp (the only thing that floats a tab to the top of the `.updated` sidebar sort) was silently dropped for floats. The resolution moved to a static `NavigatorColumn.owningTabIndex(of:in:)` over the float-aware `Session.tabIndex(containing:)` → `Tab.contains` (tree + floating layer), pinned by `NavigatorColumnSelectTests` (resolution + the recency-stamp consequence). Client-side only, no wire touch. → `NavigatorColumn.swift`
- ✅ **The `auto-hide-tabs-panel` policy no longer FIGHTS a manual ⌘⇧L: an unrelated tab open/close within the same 1↔>1 regime leaves the user's manual collapse/reveal intact (E19 WI-7 "do NOT fight a manual ⌘⇧L").** `WorkspaceRootView.applyAutoHide` previously had only a `!= desired` de-dup, so after a manual ⌘⇧L any tab-count change recomputed `desired` from the count alone and reverted the user's choice. It now records a `manualSidebarOverride` bit (set by `WorkspaceChromeState.toggleSidebar()`, the single manual entry point — ⌘⇧L / titlebar / palette; the auto path writes `sidebarCollapsed` directly, never via `toggleSidebar`, so it never sets the bit) and gates actuation on the **1↔>1 regime EDGE** (tracked via `lastAutoHideCollapsed`): on the edge the default-state opinion re-asserts and the override clears; WITHIN a regime a live override skips the write. Pinned by new cases in `SidebarAutoHideWiringTests` (override survives an in-regime tab open; edge clears it + re-asserts). Pure view state, not persisted, no wire. → `WorkspaceChromeState.swift`, `WorkspaceRootView.swift`
- ⏸️ **DEFERRED CEILING (honest gap, recorded not silently missed): the sidebar hamburger DIVIDER section ("Insert Divider" / "Remove All Dividers") is NOT built.** `SlateSortMenuButton` ships the GROUP + ORDER sections; a third DIVIDER section (`group-tabs.png`) — user-inserted section separators between sidebar tab rows — is deferred. Unlike GROUP/ORDER (pure enum writes into the already-persisted `tabGrouping`/`tabSort`), a faithful divider needs a NET-NEW store-side, stably-identified, PERSISTED divider-marker model that reconciles correctly across tab reorder / close / grouping (and the manual-reorder drag), plus a new rail row type — materially larger + riskier than this batch's envelope. Half-building it (a marker that does not survive reorder/close/persist) would be worse than the honest gap. Recorded in `E6-carryovers.md` the way the horizontal-tab-bar exclusion is, as its own future work item (NOT a wire change — client-side sidebar state). → `Chrome/SlateTabRow.swift`, [ui-shell/plans/E6-carryovers.md]

## CLI surface parity (2026-06-29) — Batch-3 audit fixes
- ✅ **`slopdesk -e <cmd> [args…]` now LAUNCHES THE GUI and forwards the command to the first pane (xterm/alacritty/ghostty parity), reversing the earlier E20 de-advertisement that made `-e` a fatal `unknownFlag` error.** The E20 rationale ("a pane is a remote PTY with no local shell to exec into") justified NOT local-exec'ing, but not a hard error vs. at least launching a window — `reference__cli.md:5,16-17` + `E20.md` WI-1 both make `-e` a first-class GUI-launch path. `CLIArgs.parse` recognizes top-level `-e` as terminal (xterm semantics): it captures every remaining token verbatim into `CLIInvocation.execCommand` (even leading-dash ones), sets `launchGUI`, and stops option parsing; after a subcommand `-e` still passes through to `rest`. `main.swift launchClientGUI(forward:)` then sends the joined command to the FOCUSED (first) pane over the existing control socket as VERBATIM UTF-8 text + a keycode `Enter` (`paneSendKeys`) — best-effort + NEVER fatal (the window is already up; `forwardSend` retries the launch race for ~5s and every failure returns instead of `die`ing). NO wire change (reuses `pane-send-keys`). Pinned by `CLIArgsTests` (`testExecFlagLaunchesGUIAndCapturesCommand`, trailing-dash verbatim capture, missing-value, after-subcommand pass-through). → `CLIArgs.swift`, `Sources/slopdesk/main.swift`
- ✅ **`font apply "<name>"` and `font import <path> [--apply]` are implemented (the help no longer promises them as "later work items" that never arrive).** `font apply` routes through the SAME running-app path as `config set font-family <name>`, so an unknown/empty name is an honest `config set rejected`, not a silent no-op. `font import` installs a `.ttf/.otf/.ttc/.dfont` into `~/Library/Fonts` (a local FS op like `config edit`; macOS auto-activates the user font dir) and, with `--apply`, resolves the file's family name via Core Text (`CTFontManagerCreateFontDescriptorsFromURL`) and routes it through the same `config set font-family` path. NO wire change. The `font apply` → font-family route is pinned by `WorkspaceControlBackendConfigTests.testFontApplyRoutesToFontFamilyConfig`; the `import` path is compiled-only (spawns FS/Core-Text I/O). → `Sources/slopdesk/main.swift`
- ⏸️ **DEFERRED CEILING (honest reject over a silent lie): `config set/unset --transient` is REJECTED with a clear reason rather than silently persisting while reporting `transient:true`.** A `--transient` flag ("apply to the running app only without persisting") relies on a config-file ⇄ running-app split that slopdesk does not have: the typed `PreferencesStore` model the renderer reads IS the same model whose `didSet` persists (there is no separate ephemeral render layer the libghostty config builder reads). The pre-fix backend ignored the flag and persisted identically while the dispatcher echoed `transient:true` — invisible to the caller. A genuine non-persisting overlay would require splitting render-source-of-truth from persistence across the typed model + the libghostty config builder — materially larger than this batch and renderer-coupled. So `ClientControlDispatcher` short-circuits any `transient` set/unset with an honest message (named flag + how to apply/revert) BEFORE the backend, and `WorkspaceControlBackend.configSet/Unset` also reject `transient` (defense in depth). The `[--transient]` promise is removed from `--help`. Pinned by `ClientControlDispatcherTests` (`testConfigSetTransientIsHonestlyRejected`, `testConfigUnsetTransientIsHonestlyRejected`) + `WorkspaceControlBackendConfigTests` (`testConfigSetTransientIsRejectedAndDoesNotApply`, `testConfigUnsetTransientIsRejected`). NO wire change. → `ClientControlDispatcher.swift`, `WorkspaceControlBackend.swift`

## Design-token + glyph consistency (2026-06-29) — Batch-4 audit polish
> Cosmetic LOW-severity parity pass — every raw literal routes through the `Slate.*` tokens / SFSafeSymbols idiom, verified against the in-repo reference screenshots.
- ✅ **Static `Image(systemName:)` literals + the arithmetic type token + chrome border literals now use the canonical idioms.** `NavigatorColumn`'s search field magnifier/clear converted from `systemName:` strings to `systemSymbol: .magnifyingglass`/`.xmarkCircleFill` (the dynamic, model-derived `Self.symbol(for:)` rows stay String-keyed — they read the registry's symbol name); `ConnectionStatusPill` replaced the re-derived `Slate.Typeface.small + 1` (= 11) with the existing **`Slate.Typeface.footnote` (= 11)** token in all three labels and switched its two chrome capsule borders from `lineWidth: 1` to **`Slate.Metric.hairline`** (matching the pane pills, `PaneStatusPills.swift`), and its retry glyph from `systemName: "arrow.clockwise"` to `systemSymbol: .arrowClockwise`; `BuildStatusPlaceholderView` routed the live-status dot + every text level off raw `Color.green`/`.secondary`/`.primary` onto **`Slate.Status.ok` / `Slate.Text.secondary` / `Slate.Text.primary`** so the headless placeholder reads as the active theme. → `NavigatorColumn.swift`, `ConnectionStatusPill.swift`, `BuildStatusPlaceholderView.swift`
- ✅ **Settings → Controls glyph corrected from `flag` (pennant) to `cursorarrow` (the pointer/cursor) — matching `all-settings.png`.** The reference screenshot shows an outlined cursor/pointer arrow beside "Controls" (the input/scroll/pointer section), never a pennant; the `SettingsSection.systemImage` String switch now returns `"cursorarrow"`. → `SettingsView.swift`
- ✅ **The composer Float button now shows a dock-back glyph (`.pipExit`) while floating, mirroring its action.** Previously the pop-out `.arrowUpForwardApp` stayed put in both states (only the help/tint toggled); it now flips to `.pipExit` — the SAME embed glyph the floating-pane card's titlebar uses (`FloatingPaneCard.swift`) — when `composer.isFloating`. → `ComposerBar.swift`
- 🚫 **(item 6) The sort/hamburger menu's selected-row indicator stays a CHECKMARK, NOT a filled-radio — the audit's "filled-radio per the screenshot" premise is contradicted by the reference screenshot.** `docs/ui-shell/screenshots/group-tabs.png` shows a **checkmark (✓)** beside the selected GROUP row ("No Grouping"); both GROUP and ORDER use the same single-select `SortRow`, so the existing `Image(systemSymbol: .checkmark)` is already clone-faithful. Switching to `.largecircleFillCircle`/`.circleInsetFilled` would DEVIATE from the screenshot, so it is deliberately not changed. → `Chrome/SlateTabRow.swift`, `group-tabs.png`
- ✅ **The floating in-pane find-bar CARD drops its hairline stroke — `find.png` delineates the card with its FILL + drop SHADOW only, no border.** Pixel-scanning `find.png` across the card's top/bottom padding bands shows the pane→shadow gradient (227→…→207) transitioning STRAIGHT into the card fill (245) with no crisp `Line.subtle` border line; the only hairline outlines in the screenshot belong to the individual `Aa`/`ab`/`.*` mode chips (`FindTogglePill`), not the card. `TerminalFindBar`'s container drew a `RoundedRectangle(radiusControl).strokeBorder(Line.subtle)` overlay contradicting that — removed; the `Surface.element` fill + the `State.shadow` drop shadow stay. The `GlobalSearchView` query-field plate's hairline border is UNCHANGED (it IS present in `global-search.png` — verified by zoom — because that field sits on bare `Surface.window` and needs the ring to read as a plate; the two readings are independently screenshot-faithful). → `Pane/TerminalFindBar.swift`, `find.png`
- 🚫 **(items 1 + 2) The command-palette + Open-Quickly SELECTED-ROW fill stays inset by `space2` with `radiusItem` corners — the audit's "edge-to-edge / full-width (zero inset)" remedy is contradicted by pixel-measuring the reference screenshots.** In `command-palette.png` (panel left edge x=112) the selected "Copy Path" fill begins at x=128 (16px inset) while the search-bar magnifier — padded `space4`=16pt — begins at x=145 (33px inset): the highlight inset is EXACTLY half the magnifier inset, i.e. `space2`=8pt, and the fill even extends slightly LEFT of the `space3`=12pt section header — precisely the `.padding(.horizontal, space2)` the current `PaletteView.actionRow`/`OpenQuicklyView.row` already render (`open-quickly.png` measures the same ~9pt symmetric inset, also NOT touching the panel edge). The plans' word "full-width" (`E2.md:156`, `E11-carryovers.md:141`) describes a full-width BAR (vs a text-hugging pill), which the inset rounded fill already is; making it touch the panel edge would DIVERGE from the source-of-truth screenshots, so the inset rounded fill is deliberately kept. → `Overlays/PaletteView.swift`, `Overlays/OpenQuicklyView.swift`, `command-palette.png`, `open-quickly.png`

## Command-palette + menu catalog completeness (2026-06-29) — Batch-4 audit polish
- ✅ **Theme / Config verbs are in the ⌘⇧P palette ("Theme: Switch Theme / Open Theme File" + "Settings: Reload Config"), each routing a real handler.** Theme is LOCAL client state, so the three rows (`action.switchTheme` / `action.reloadConfig` / `action.openThemeFile`, under the SETTINGS section) route through new injected `OverlayCoordinator` closures the app binds to the live stores: **Reload Config** → `PreferencesStore.reapplyLiveSettings()` + the `WorkspaceControlBackend.configReloadNotification` broadcast (the CLI `config reload` analog — slopdesk has no hand-edited TOML, so re-applying the live typed model is the faithful equivalent); **Open Theme File** → reveal `~/.config/slopdesk/themes/` in Finder via `NSWorkspace` (created on demand), macOS-only (iOS has no `~/.config` → documented no-op). → `Palette/PaletteDataSource.swift`, `Palette/PaletteModel.swift`, `Overlays/OverlayCoordinator.swift`, `SlopDeskClientApp.swift`
- 🔁 **DIVERGENCE (honest, recorded): the palette "Switch Theme" verb CYCLES the built-in themes live rather than opening a grid PICKER.** A dedicated grid picker was considered, but slopdesk's theme grid lives in Settings → Appearance and there is no standalone palette theme-picker overlay (and the in-window `OverlayCoordinator.settingsVisible` settings surface is not yet mounted — a separate pre-existing gap). So `action.switchTheme` advances the primary `appearance.theme` slot through the shipped built-ins (`SlopDeskClientApp.nextBuiltinTheme(after:)`, Settings → Appearance order, wrapping; the SAME live slot the picker edits — chrome retints + terminal cells repaint immediately), making the verb a real, visible theme switch instead of a dead/latent control. Pinned by `PaletteContentAndReachTests` (catalog presence + the injected-closure run path). → `Palette/PaletteDataSource.swift`, `SlopDeskClientApp.swift`
- ✅ **The five NAMED layout presets (`select-layout`) are now palette rows under PANE — the documented "menu/palette only" entry point existed on NEITHER surface before.** The registry tracks `.applyLayout(_)` as palette/menu-only but listed only the chorded `.cycleLayout`; the five presets (`action.layoutEvenHorizontal/EvenVertical/MainVertical/MainHorizontal/Tiled`, titled "Layout: …") are now `.store` rows calling `WorkspaceStore.applyLayout(_:)` directly (a graceful no-op on a 0/1-leaf tab), chord-less ⇒ no hint chip. (A Pane ▸ Layouts menu submenu remains optional — the palette satisfies the documented reach.) → `Palette/PaletteDataSource.swift`
- ✅ **The rest of the Agents menu — Prompt Queue + Send to Chat — are in the palette under AGENTS (Open Composer already was), so they are reachable cross-platform (iOS has no Agents menu).** `action.promptQueue` is a `.store` arm (`requestPromptQueueInActivePane()`); `action.sendToChat` routes the coordinator's `.openSendToChat` dialog (the SAME ⌘⌃↩ surface the menu mirrors, which HONESTLY no-ops with a toast when there is nothing to quote). CLAUDE-only. → `Palette/PaletteDataSource.swift`, `Palette/PaletteModel.swift`, `Overlays/OverlayCoordinator.swift`
- ✅ **"Prevent Sleep While Processing" is on the tab right-click context menu (`open-code-agent-history.png`), no longer "a follow-up".** The host-LOCAL `AgentPreferences.preventSleep` flag (default-OFF, sidecar → applies on reconnect) needed `PreferencesStore` threaded into the AppKit split-view host (the macOS sidebar `NSHostingController` does not inherit the WindowGroup `\.preferencesStore` environment): `WorkspaceRootView` → `WorkspaceSplitRepresentable` → `SlopDeskSplitViewController` → `NavigatorColumn` now passes it explicitly (iOS inherits it but is passed it too for parity), and `rowContextMenu` adds the `Toggle` bound to the GLOBAL `agent.preventSleep` (slopdesk implements Prevent Sleep as one host-LOCAL flag, not per-tab — the SAME flag Settings → Agent Behaviour edits; a `nil` store hides the row). iOS UIKit slice touched → run `bash scripts/check-ios.sh`. → `Columns/NavigatorColumn.swift`, `App/SlopDeskSplitViewController.swift`, `WorkspaceRootView.swift`

## Terminal defaults + input toggles (2026-06-29) — Batch-4 audit polish
> LOW-severity TERM / keyboard-input parity pass. Host ENV (`TERM`) is OFF-wire and `macos-option-as-alt` is a client-side libghostty config string — the golden corpus is untouched by all of these.
- 🔁 **DELIBERATE CHOICE (rationalized): the host PTY `TERM` default stays `xterm-ghostty`, not a conservative `xterm-256color` — because slopdesk's renderer genuinely IS libghostty.** A conservative terminal that is NOT itself a ghostty implementation would need to avoid setting `term = xterm-ghostty`: claiming to be one would make programs emit kitty/DEC-2026 sequences it cannot render. slopdesk's CLIENT renders the PTY stream with **libghostty** behind `TerminalSurface` — a real ghostty emulator that DOES interpret those sequences — so `xterm-ghostty` is the genuinely-correct capability database for what the client can display (kitty keyboard protocol, DEC 2026 synchronized output). The one real risk that concern would guard against (a TUI on the host calling `setupterm("xterm-ghostty")` on a box that lacks the entry) is ALREADY mitigated, independent of this default, by `TerminfoResolver` (Ghostty #54700 model): it probes the host terminfo DB and auto-falls-back to `xterm-256color` when the entry is unresolvable, and an operator can force `--xterm256`. So we keep the feature-rich default with a safe fallback rather than a needlessly conservative default that would drop ghostty features our own renderer supports. → `ClaudeCodeProfile.swift`, `TerminfoResolver.swift`, `HostEnvironment.swift`
- ✅ **"Option as Alt" is now a real Settings → Controls → Keyboard toggle wired to libghostty `macos-option-as-alt`.** The macOS Option→Alt/Meta decision is made by the CLIENT's libghostty surface (it owns key→byte encoding, emitting bytes over the wire), and `macos-option-as-alt` is a verified stock ghostty config key (`input/config.zig` enum `false`/`true`/`left`/`right`) — so it is reachable through the existing headless `TerminalConfigBuilder` → `ghostty_config_load_string` seam, NOT renderer-internal plumbing. A new 4-state `OptionAsAlt` enum (Off / Both / Left / Right; persistence tokens `off`/`both`/`left`/`right`, libghostty token via `configValue`) rides `TerminalControls` → `TerminalControlsConfig` → the builder's control block, persisted as the fire-time `Defaults` key `controls.optionAsAlt` (default Off, repaired via `PreferRawRepresentable`), surfaced in the Controls Keyboard section + the searchable All-Settings list, and covered by the reset sets. Pinned headlessly by `TerminalConfigBuilderControlsTests` (`testOptionAsAltTokenPassesThroughVerbatim`, `testDefaultOptionAsAltIsFalse`) + `TerminalControlsTests` (`testOptionAsAltRawValuesAndConfigValue`, `testFactoryReadsOptionAsAlt`). → `TerminalControls.swift`, `TerminalConfigBuilder.swift`, `SettingsKey.swift`, `PreferencesStore.swift`, `SettingsView.swift`, `AllSettingsCatalog.swift`, `AllSettingsListView.swift`
- ⏸️ **DEFERRED CEILING (no stock config key — honest gap over a fake toggle): "Kitty Keyboard Protocol" + "Allow VT100 Application Keypad Mode" are NOT surfaced as Settings toggles.** Both toggles have NO corresponding stock libghostty config key — grepping the vendored ghostty `config/Config.zig` finds neither a `kitty-keyboard`/`keyboard-protocol` key nor an application-keypad key (the protocol is negotiated at runtime by the program via CSI sequences and the emulator always honours it; DECKPAM is an emulator mode with no enable/disable config). Exposing a faithful toggle would require forking the libghostty keyboard/emulator layer to add a gate — renderer-target-only plumbing not reachable through the headless config-string seam — which is out of scope for a LOW-severity polish item. Recorded as an honest gap rather than a dead toggle that persists but does nothing (the same discipline as E14's `titleReport` ceiling). → `ThirdParty/ghostty/.work/ghostty-src/src/config/Config.zig`
- ✅ **The Settings → Appearance → Cursor live-preview prompt colours now match `cursor-style.png`: `john` green, `@doe-pc` muted blue-gray, the rest default foreground.** The mock renders the host run (`@doe-pc`) in a muted blue-gray DISTINCT from the green user (`john`); the pre-fix preview rendered `doe-pc` in the SAME green (`Slate.Status.ok`) and split `@` onto the foreground, so user and host read identically. `@doe-pc` is now one run on the `Slate.Status.info` blue token (the closest theme-aware blue-gray in the token palette — raw hex would break the file's Slate.*-tokens-only discipline), faithful to the screenshot's user/host colour split. Cosmetic, client-only. → `CursorPreviewView.swift`, `cursor-style.png`

## Details / recipes / remote-window / theming / web-pane (2026-06-29) — Batch-4 audit polish
> LOW-severity details-panel / recipes / remote-window / theming / web-pane parity pass. All client-side: no wire-format change, golden corpus untouched (the host ENV / config-string seams stay off-wire).
- ✅ **(item 1) The Details Info-tab agent section is the AGENT-PANE section ("Claude Code"), gated on the live agent pane, and adds Copy Session ID — matching `info-panel.png`'s agent section.** It was labelled "Sessions" and gated on whether on-disk sessions existed (`!agentSessions.isEmpty`); it now reads `SlateSectionHeader("Claude Code")` (the agent name per the Claude-only scope), shows whenever the focused pane is a LIVE agent (`isAgentPane` = `claudeStatus != .none`, so a freshly-started agent shows it immediately), and carries **Copy Session ID** (writes the pane's `LivePaneSession.liveAgentSessionID` to the pasteboard, disabled until known) above **View Session History**. `liveAgentSessionID` is now `public` so ClientUI can read it. A separate "Fork in…" agent-fork surface is not added here (out of scope for this item). → `Columns/InspectorColumn.swift`, `Workspace/Store/LivePaneSession.swift`
- ✅ **(item 2) The ⌘S Save-Recipe Commands-scope list is DOUBLE-CLICK-to-edit, not an always-editable field (spec §Custom Commands "double-click any item to edit").** Each command row is now display-only plain text until double-clicked; only the editing row (`editingRowID`) swaps to a focused `TextField`, and a focus loss / Enter ends edit mode. → `Recipes/RecipeSaveSheet.swift`
- ✅ **(item 3) The Edit-Text-Snippet sheet's Text area gains a bottom-right drag-resize grip (`textsnippet-setting.png`).** SwiftUI `TextEditor` exposes no native resize grip, so the handle is a manual diagonal-hatch grip driven by a `DragGesture` (height captured at drag-start, clamped to a 120pt floor via the ordered `CGFloat.maximum` house idiom) — the floating-pane card's corner-grip pattern reused. → `Settings/SnippetEditorSheet.swift`
- ✅ **(item 4) A remote window with an EMPTY host-title shows the app name on ONE line only (both the rail + Open-Quickly), preserving the two-line intent.** When the streamed window has no title, `newRemoteWindowTab`/`addSystemDialogPane` collapse the LABEL to the app name, so the display title (line 1) AND the streamed window title both become the app name — printing the host app on line 2 duplicated it. `PaneSpec.railSubtitle` now suppresses the host-app subtitle to a single line ONLY in that all-collapsed case (line1 == app == window-title); `OpenQuicklyModel.paneRowSubtitle` suppresses the app subtitle when it equals the line-1 title. A window WITH a real title keeps line 1 distinct, so the labelled-window subtitle still shows. Pinned by `RemoteGUIFirstClassPeerTests` (empty-title → nil; present-title → "Safari"). → `Workspace/Domain/PaneSpec.swift`, `Workspace/Domain/OpenQuicklyModel.swift`
- ✅ **(item 5) The floating-pane card grab-strip title tracks the LIVE `lastKnownTitle` (the rail/titlebar/status-bar source), not the static spec `title`.** It read `spec?.title` (the stale launch title); it now prefers `spec?.lastKnownTitle` (the live OSC 0/2 / page title) with the spec title + a generic fallback. → `Pane/FloatingPaneCard.swift`
- ✅ **(item 6) Theme import ADDS to the library WITHOUT auto-switching by default; a "Switch to it now" checkbox opts into activation (themes spec §Import).** `importTheme` always called `activate(slug:)`; it now routes the pure `ThemeEditorView.importOutcome(slug:switchToImported:)` decision (default OFF ⇒ add-only, ticked ⇒ activate), with a checkbox next to the Import menu. Pinned by `ThemeImportSwitchTests`. → `Settings/ThemeEditorView.swift`
- ⏸️ **(item 7) DEFERRED — honest gap: the `.slopdesktheme` `[cursor].style` / `[cursor].blink` / `[ghost].foreground` keys are NOT consumed (not parsed into `ThemeDocument`, not forwarded to the renderer).** The audit's "parsed-but-ignored" is imprecise — `ThemeTOMLParser` reads only `[cursor].color`, never these keys. Wiring them END-TO-END is genuinely renderer-coupled and disproportionate to a LOW item: slopdesk's `ResolvedTerminalTheme` forwards ONLY cell `background`/`foreground`/`palette`/`selection-background` to libghostty (`TerminalConfigBuilder`); even the existing per-theme `cursor`/`cursor-text` COLORS are not forwarded. Per-theme cursor SHAPE/BLINK are already owned by the global Settings → Cursor controls (`cursor-style`/`cursor-style-blink`, which DO reach the renderer), and `[ghost].foreground` maps to libghostty ghost-text styling with no `TerminalConfigBuilder` key. Parsing them into a never-consumed `ThemeDocument` field would just RE-CREATE the "parsed-but-ignored" smell, so they are left unparsed and the gap is recorded honestly rather than faked. → `Settings/ThemeTOMLParser.swift`, `Workspace/Store/AppearanceApplier.swift`
- ✅ **(item 8) The leftmost web-toolbar ✗ is STOP while a page loads, falling back to Close pane when idle (`web-broswer.png`).** `WebPaneController` gained `isLoading` + `stop()` + `updateLoading(_:)`; `WebPaneModel` surfaces `isLoading`/`stop()`; the leftmost button flips help + role on `model.isLoading` (Stop → `stopLoading()`, else `requestClosePane`). The production `WebPaneView` (app target) wires `stopLoading()` and pushes loading state from `didStartProvisionalNavigation`/`didFinish`/`didFail`/`didFailProvisionalNavigation`. Pinned headlessly by `WebPaneStopLoadingTests` (no `WKWebView`). → `Web/WebPaneSeam.swift`, `Pane/WebLeafView.swift`, `Apps/Shared/WebPaneView.swift`
- ✅ **(item 9) The Open-Quickly Folder ⌘K actions add "Split Right" / "Split Down" (`open-quickly.png`).** The folder action table (extracted to the testable static `OpenQuicklyView.folderRowActions`) now opens a fresh terminal split rooted at the folder — reusing `WorkspaceStore.openTerminalRooted`, widened with an `axis` parameter (default `.horizontal`) so Split-Down is a vertical split. "Open in New Window" stays N/A in the single-window model (omitted, not a dead row). Pinned by `OpenQuicklyFolderActionsTests` (titles present) + `WebPaneStoreTests` (`axis: .vertical` ⇒ a vertical split). → `Overlays/OpenQuicklyView.swift`, `Workspace/Store/WorkspaceStore+Drop.swift`
- ⏸️ **(item 10) DEFERRED — tied to the Editor-settings placeholder: the Key Bindings pane has no TEXT/SEQUENCE or COMMANDS/RECIPE sub-sections.** Those belong to a fuller Editor / Recipes editor surface, which is an intentionally-deferred placeholder (the Editor settings section is a known scope reduction). Building a new keybinding-editor surface for them here is out of scope; they are recorded as a deferred gap to land WITH the Editor-settings surface rather than bolted onto the current Key Bindings pane.

## Composer + find-bar chrome (2026-06-29) — Batch-5 audit polish
> Two cosmetic LOW-severity chrome deltas, both client-side SwiftUI view layer — NO wire change, golden corpus untouched, `Slate.*` tokens only. Build + lint gate (DS-leaks, SwiftFormat, SwiftLint `--strict`) is the proof for both; no behavioral logic changed, so no revert-to-confirm-fail test applies.
- ✅ **(D) The Composer action row now divides Send / Queue / Cancel with a muted interpunct "·" — matching `composer.png`.** The bottom-left hint row rendered the three groups (`⌘↩ Send` / `⌥⌘↩ Queue` / `⎋ Cancel`) with only the `HStack`'s bare `space2` gaps; `composer.png` renders an interpunct **"·"** between each group. Added an `actionSeparator` view (`Text("·")` at `Typeface.footnote`, `Text.tertiary`) between the three `hintButton`s — the SAME separator idiom the block caption already uses (`BlockRowView`: tertiary dot between secondary labels). Only the normal Composer branch (`composer.png`) gets the dots; the Prompt-Queue branch (`queue.png` — Close + queue glyph only) is unchanged. → `Pane/ComposerBar.swift`, `composer.png`
- ✅ **(B) The find-bar query field now reads as a distinct FILLED gray rounded INSET inside the card (`find.png`), not flush text on the card.** `find.png` shows the query text in its own delineated, sunken gray field within the find-bar card; the clone floated the field on a `Surface.card` fill that — because the card itself is `Surface.element` (≈ white/elevated in light themes, where a flush `Surface.card` field is near-invisible) — did not delineate. **Token choice rationale (pinned so it is not re-litigated):** there is NO solid medium-gray *Surface* token that sits reliably BETWEEN white and the backdrop across themes (the generated Monokai/`document` factories set `element` = white in light and `card` = bg; Paper inverts the two), so a solid surface token cannot give a faithful "gray inset" everywhere. The field instead wears **`State.selected`** — a translucent neutral wash that composites over the `element` card to a gray inset. **Cross-theme correction (see Batch-5b note at EOF):** `State.selected` is a BLACK wash in light (composites DARKER than the card → recessed, matching `find.png`) but a WHITE wash in dark (composites *lighter* than the card → which on its own reads RAISED, **not** recessed — the earlier "conventional recessed-field look" wording was wrong for dark). Batch-5b therefore adds an inner `Line.subtle` hairline to the query field so it reads as a delineated inset regardless of fill-contrast direction. This changes ONLY the inner field's fill (+ now its inner hairline); the card's no-border / fill+shadow chrome (the Batch-4 `find.png` decision above, line ~396) is deliberately untouched — the outer stroke is NOT re-added. → `Pane/TerminalFindBar.swift`, `find.png`

## Settings section-header typography (2026-06-29) — Batch-5 audit polish
> One MED-severity typography parity fix, client-side SwiftUI view layer only — NO wire change, golden corpus untouched, `Slate.*` tokens only.
- ✅ **In-page Settings SECTION headers now render UPPERCASE / letter-tracked / secondary-gray — a signature small-caps section-label style (`mouse-option.png` "MOUSE"/"SECURE INPUT", `notification-setting.png` "NOTIFICATION"/"TAB BADGE", `all-settings.png` "ALL SETTINGS") — instead of macOS's default Title-Case bold-dark `Section("…")` header.** The clone's grouped-`Form` settings pages used the native `Section(_ titleKey:content:)` initializer, which on macOS renders Title-Case dark headers ("Selection", "Copy & Paste", "Close Confirmation"), diverging from the app's OWN command-palette section headers (`PaletteView.sectionHeader`: `Slate.Typeface.small` semibold · `.tracking(0.8)` · `Slate.State.header`), which already render correctly. There was NO shared section-header component — each section was a per-section native literal. Fix CONSOLIDATES all 45 header-bearing grouped-Form sections onto one shared `slateFormSection(_:content:)` helper (new `Settings/SettingsSectionHeader.swift`) whose custom `header:` view carries the SAME three palette tokens, so the Settings form and the palette no longer diverge. Each call site is a pure initializer rename (`Section("X") {` → `slateFormSection("X") {`); the content closures are byte-identical, so no section body moved. The underlying `GeneralSettingsLayout.*` title CONSTANTS stay Title-Case (uppercasing happens only at render via the pure, testable `SlateSettingsSectionHeader.label`), so `SettingsSectionTaxonomyTests` / `GeneralSectionLayoutTests` (which pin the title strings) are unaffected. **Deliberate divergence (pinned):** macOS grouped-Form headers are natively Title-Case; rendering them in the iOS-style uppercase-tracked treatment is an intentional design choice, not a platform-HIG miss. Headerless `Section { … }` groupings (footer-only / ungrouped chrome) stay native — they carry no title to restyle. Casing pinned by `SettingsSectionHeaderTests` (revert-to-confirm-fail: drops to the raw Title-Case title ⇒ fails). → `Settings/SettingsSectionHeader.swift`, `Settings/SettingsView.swift`, `Settings/FontSettingsView.swift`, `Settings/CursorPreviewView.swift`, `Settings/WorkspaceTransferDocument.swift`, `mouse-option.png`, `notification-setting.png`, `all-settings.png`

## Batch-5 JUDGMENT items — sidebar tab badge + find-bar "search all tabs" (2026-06-29)
> Two judgment-call fidelity items, both INVESTIGATED then fixed faithfully (the intended function was determinable in both cases, so neither was deferred). Client-side SwiftUI/AppKit view layer only — NO wire change, golden corpus untouched, `Slate.*` tokens + SFSafeSymbols only. SCREENSHOTS outrank spec prose throughout.
- ✅ **(1) Sidebar tab row's trailing badge is now the `⌘N` SWITCH-SHORTCUT (⌘1…⌘9), not the old `#N` hash-index.** Evidence: `find.png` and `workspace-tabs.png` (reference screenshots, `docs/ui-shell/screenshots/`) both render the trailing chip with the **command pictograph + tab number** — the live ⌘1…⌘9 select-tab chord — including on the active white-card row (glyph "⌘" + digit, NO process label). A prior E6 note chose `#N`, but the SCREENSHOT outranks it. The badge is gated to tabs **1…9** (the only tabs with a ⌘N chord) via the pure `SlateTabRow.shortcutBadge(for:)`; overflow tabs (10+) render no shortcut (not a misleading `⌘10`) and fall back to the process label. **Deliberate divergence retained (pinned):** slopdesk shows the badge PERSISTENTLY rather than only revealing the `⌘N` hint while ⌘ is held. The ⌘-hold reveal was tried-and-rejected earlier (hold-to-hint keycaps judged unattractive), so the persistent display stays; this batch only corrects the badge TEXT (`#N` → `⌘N`) and the 1…9 gate. The active-row process label is unchanged (`tab-badge.png` shows `zsh` on the active idle row). Pinned by `SlateTabRowBadgeTests` (revert-to-confirm-fail: reverting the formatter to `#N` or dropping the overflow gate fails the `⌘N` / 1…9 / nil assertions). → `Chrome/SlateTabRow.swift`, `Columns/NavigatorColumn.swift` (iOS row), `find.png`, `workspace-tabs.png`, `tab-badge.png`
- ✅ **(2) Find-bar `rectangle.stack` "search all tabs" button — IDENTIFIED and implemented (not dead chrome).** `find.png` shows a box / stacked-rectangle icon button between the next-match chevron (∨) and the close (×); its function was undocumented in the earlier spec notes (stale prose that also omitted the `ab` whole-word chip visible in the live PNG). The intended function — ESCALATE the in-pane find to cross-tab **Global Search (⇧⌘F)**, which slopdesk already owns (`OverlayCoordinator.openGlobalSearch(seed:)`) — was determined from the icon + surrounding find-bar layout. Implemented as an `SlatePlateButton(symbol: .rectangleStack, …)` in that exact slot, wired through `TerminalFindBarModel.searchAllTabs()` → seeds Global Search with the live find query → dismisses the in-pane bar. `TerminalLeafView.wireFindCallbacks()` binds the seam to the overlay coordinator (cleared in `clearFindCallbacks()`). This supersedes the earlier "DELIBERATE OMISSION pending confirmation" comment in `TerminalFindBar.swift` — the affordance is now confirmed and wired. Pinned by `TerminalFindBarModelTests.testSearchAllTabsEscalatesWithSeededQueryThenCloses` (revert-to-confirm-fail: the `searchAllTabs()` / `onSearchAllTabs` seam did not exist, so the seeded-query escalation + auto-dismiss both fail without it). → `Pane/TerminalFindBar.swift`, `Pane/TerminalLeafView.swift`, `find.png`

## Command-palette WD-pill resolution + section-header alignment (2026-06-29) — Batch-5b audit polish
> Two command-palette fidelity items vs `command-palette.png` (one MED, one LOW). Both fixed cheap-correct (neither deferred) — client-side view layer only, NO wire/golden change (the cwd resolution reuses the EXISTING `cwd()` metadata RPC — no new wire message), `Slate.*` tokens + SFSafeSymbols only. SCREENSHOT outranks spec prose throughout (the live `cap-02-palette.png` was compared against `command-palette.png`).
- ✅ **(A) The WORKING DIRECTORY header's cwd PILL now renders for a connected pane — the prior Phase-C claim that it "already exists since E2 (684241b)" was true of the VIEW but the pill never had data to show on a fresh prompt.** ROOT CAUSE: `PaletteView.cwdBadge` renders only when `workingDirectory` (= the focused pane's `PaneSpec.lastKnownCwd`) is non-nil, but `lastKnownCwd` had only TWO runtime writers — `refreshCwd` fired from `wireMaterializedLeaf`'s `onCommandCompleted` (OSC 133;D, i.e. only AFTER a command completes) and `InspectorColumn.bindAndRefresh` (only while the Details/Info tab is mounted; the inspector is frequently collapsed). So on a freshly-connected pane sitting at a prompt with the inspector hidden — exactly the live capture — neither had fired and the pill was blank, even though the host knew the cwd. FIX: a new injected `OverlayCoordinator.resolveActiveCwd` closure, fired from `openPalette(mode:query:)`, EAGERLY resolves the focused pane's cwd via the SAME live-metadata path the inspector + Open-Quickly already use (`store.handle(for:) as? LivePaneSession → connection.activeMetadataClient.cwd()` → `store.setLastKnownCwd`), bound cross-platform in `WorkspaceRootView.wireOverlayCwdResolver()`. The resolution lands reactively (`@Observable` spec write) within ~1 RTT, so the pill pops in without blocking the open; a disconnected pane / nil client / empty cwd is a silent no-op (validate-then-drop). Pinned by `OverlayCoordinatorMountTests.testOpenPaletteFiresActiveCwdResolution` (revert-to-confirm-fail: drop the `resolveActiveCwd()` call from `openPalette` ⇒ the injected closure never fires). → `Overlays/OverlayCoordinator.swift`, `WorkspaceRootView.swift`, `command-palette.png`
- ✅ **(B) Palette SECTION headers are now FLUSH with the row labels (the ✓/icon gutter to their LEFT), matching `command-palette.png`.** The clone's `sectionHeader` text sat at only `space3` from the panel edge while an action `actionRow`'s LABEL sat at `space2`(outer inset) + `space3`(inner) + 20(✓ gutter) + `space2`(HStack spacing) = 48pt — so labels were indented ~36pt RIGHT of their headers (the reported "~40px"). `command-palette.png` shows the uppercase header text and the row labels sharing ONE left margin with the ✓/icon gutter sitting to its LEFT. FIX: gave the header the same leading geometry as the row — a 20pt empty `Color.clear` gutter placeholder (headers carry no glyph) + `.padding(.leading, space2)` outer inset on top of the existing `.padding(.horizontal, space3)` — so the header text lands at the EXACT same x as a label (`space2 + space3 + 20 + space2`). The action row's Batch-4 inset selected-row highlight + ✓-gutter are UNTOUCHED (only the header moved). No behavioral seam ⇒ proven by the build + DS-leak/SwiftFormat/SwiftLint-strict gate (raw `Color.clear` + numeric `frame(width:)` are not token-leaks; the ds-leak ratchet bans only font/`cornerRadius` literals, and `Color.clear` is already the file's idiom). → `Overlays/PaletteView.swift`, `command-palette.png`
- ✅ **(C) The cwd pill now HOME-ABBREVIATES (`/Users/abner/Workplace/myproj` → `~/Workplace/myproj/`), matching the reference screenshot's tilde-abbreviated, trailing-slash cwd format.** Bullet (A) populated the pill with the RAW absolute path the `cwd()` RPC returns (no `~`, no trailing slash); the screenshot shows the home prefix collapsed to `~` plus a trailing directory slash. The cwd is a REMOTE-host path, so the abbreviation matches the home by SHAPE — `/Users/<name>` (macOS) or `/home/<name>` (Linux) — NEVER `NSHomeDirectory()` (the CLIENT's own home, wrong for a remote host). No existing helper did this (the E21 `PaneSpec.railSubtitle` shows the raw cwd; `PortablePaths` is the recipe-template domain), so a new pure `CwdDisplay.abbreviate` (a SwiftUI/AppKit-free enum in `PaletteView.swift`) was added: empty stays empty, root `/` stays `/`, an already-`~`-rooted path keeps its `~`, a non-home path keeps its path — all gaining the directory slash. Pinned by `CwdDisplayTests` (revert-to-confirm-fail: removing the tilde collapse fails the tilde-abbreviation assertions; removing the trailing-slash marker fails every case). → `Overlays/PaletteView.swift`, `command-palette.png`
- ✅ **(D) The cwd pill's RIGHT edge now lines up with the action-row keycap-chip column (`command-palette.png`: pill + keycaps share one right edge).** The WORKING DIRECTORY header's trailing inset was only `.padding(.horizontal, space3)` = 12pt while the action rows get `space3 + space2` = 20pt (the keycap chips sit at that 20pt inset), so the pill jutted `space2` (8pt) further RIGHT than the keycap column. FIX: a matching `.padding(.trailing, space2)` on the section header (→ 12 + 8 = 20pt) so both share the right edge. The bullet-(B) LEADING-flush geometry (header text flush with row labels) and the row's Batch-4 inset highlight are untouched. No behavioral seam ⇒ proven by the build + DS-leak/SwiftFormat/SwiftLint-strict gate. → `Overlays/PaletteView.swift`, `command-palette.png`

## Find-bar query-field cross-theme delineation (2026-06-29) — Batch-5b audit polish
> One regression-lens fidelity item flagged by the Batch-5 review of the find-bar inner query field (DECISIONS line ~429). Cosmetic, client-side SwiftUI view layer only — NO wire/golden change, `Slate.*` tokens only (no raw `Color`/hex/`lineWidth`). Build + lint (DS-leaks, SwiftFormat, SwiftLint `--strict`) is the proof; no behavioral seam, so no revert-to-confirm-fail test applies (purely a `.overlay` stroke). SCREENSHOT (`find.png`, a LIGHT capture) outranks spec prose.
- ✅ **The find-bar query field gains an inner `Line.subtle` hairline so it reads as a clearly-delineated INSET on BOTH light and dark themes — fixing a dark-theme regression latent in the Batch-5 `State.selected` fill.** Batch-5 (commit `47be3b4`) switched the inner field from `Surface.card` to **`State.selected`** so the query text sits in a delineated gray inset matching `find.png`. That was validated only against `find.png` (LIGHT), and its note claimed the dark composite was "the conventional recessed-field look" — **which is wrong.** INVESTIGATION of the actual tokens (`SlateDesign.swift` `monokai(_:)` factory + the `Slate.*` accessors): the find-bar CARD fill is `Surface.element` (the seed's `elevated` surface), and `State.selected` is `line.opacity(…)` where `line == .white` in dark, `.black` in light. Composited over the default Monokai Pro Classic card (`element` = `#403E41` = rgb(64,62,65)): `State.selected` (white @0.09) = **rgb(81,79,82) — LIGHTER** than the card, i.e. it reads RAISED, not recessed. In light (`element` = white) the same token is black @0.07 = rgb(237,237,237), DARKER than the card → correctly recessed (matching `find.png`). So the fill's contrast direction INVERTS by theme. **Why not just pick a darker token (Option 2)?** No single token is reliably recessed-AND-visible on both: the only darker-than-card token in dark is `Surface.card`/the backdrop (`#2D2A2E`), but in light that backdrop is paper (`#FAF4F2`) sitting on a white card — a delta of only ~29/765, near-invisible (exactly the flush-field problem Batch-5 set out to fix); and every dark wash (`hover`/`selected`/`accentMuted`) is white-based, so none darkens the dark card. **Resolution (Option 1 — most robust):** keep the VISIBLE `State.selected` fill (correct in light, and a visible delineating wash in dark) and add the field's OWN inner `Slate.Line.subtle` hairline (`.overlay(RoundedRectangle(radiusSmall).strokeBorder(Line.subtle, hairline))`). The hairline is a hard field boundary that delineates the inset REGARDLESS of which way the fill contrasts — so it is correct on every current theme AND robust to future theme value shifts (it never assumes the fill is darker), which a theme-conditional `isLight ? … : …` fill would not be. **Honesty correction (a prior overstatement retracted):** `find.png`'s find-bar interior is in fact a near-UNIFORM gray plate — the query text sits flush on it, and the only delineated elements are the `Aa`/`ab`/`.*` mode pills; there is NO faint edge at the query-field boundary (the earlier "`find.png`'s light inset carries a faint edge, verified by zoom → screenshot-faithful in light" wording was wrong and is withdrawn). So the inner `State.selected` fill + `Line.subtle` hairline are an ACCEPTED cross-theme delineation APPROXIMATION — load-bearing for the DARK default theme (where the white-based fill alone reads RAISED, so a hard boundary is needed), NOT a pixel match to the reference design's flatter uniform-plate query area. The truly-1:1 alternative (recoloring the find-bar CARD from white to gray so a flush field reads as an inset without any added fill/hairline) was DECLINED to avoid re-litigating the Batch-4-pinned card `Surface` token (line ~396, the no-border fill+shadow card) — a deliberate fidelity trade, not a claimed match. This is the INNER field only — the Batch-4 decision that the OUTER card wears no stroke (just fill + drop shadow) is untouched; the outer card border is NOT re-added. The Batch-5 note (line ~429) was corrected in place to retract the "lighter in dark = recessed" wording. → `Pane/TerminalFindBar.swift`, `find.png`

## Extension surface — 6 LARGE features INTENTIONALLY NOT BUILT (2026-06-29) ⛔ binding scope

> The 2026-06-29 docs-driven coverage audit (`docs/ui-shell/COVERAGE.md`, run `wj7db1mx1`) found 6 large candidate features that were never built. **User decision (2026-06-29, verbatim intent): mark them as intentionally NOT built so future sessions don't touch them.** These are deliberate scope exclusions, NOT gaps — the current feature set is the *foundation*; these are the user's own extension surface, to be built later only on the user's explicit by-name request.
- ⛔ **A future session / agent MUST NOT implement, scaffold, "fix", or flag as a coverage gap any of:** (1) Autocomplete — inline ghost text + Fig spec DB (715+ tools) + frecency + auto-correction; (2) File pane / Folder pane — built-in editor (syntax highlight + Markdown/SVG/HTML/image/PDF/hex/diff preview) + standalone folder browser (also the deferred Editor-settings, Task #14); (3) Quick Terminal — system-wide global-hotkey drop-down terminal; (4) cross-terminal config import/export — ghostty/kitty/alacritty classification + `slopdesk import`/`export` CLI; (5) Theme catalog — Nord + the ~24 built-ins (the clone deliberately ships 8 with Monokai Pro default); (6) bash / fish shell integration (the clone is zsh-only). The smaller deferred niceties listed in COVERAGE.md §E are likewise intentional non-builds. Build any of these ONLY when the user explicitly asks for it by name. See COVERAGE.md §E.

## Queue-safety cluster — agent prompt dispatch, hook stickiness, honest hook status (2026-07-02)

> Post-audit fix cluster (2026-07-02 feature audit → queue-safety). SAFETY-CRITICAL contract change: **a queued prompt must NEVER be executed by the shell.** No WireMessage layout / type byte / golden-vector change; the only wire-visible delta is the verb-13 `agentHookStatus` RESPONSE payload growing 1 → 2 bytes (additive + forward-tolerant, documented in docs/20).

- ✅ **Prompt-Queue dispatch contract (E12 revision): per-TARGET dispatch.** Every queued prompt is stamped at enqueue with the pane mode it was written for (`PromptQueueItem.target`: `.shell` | `.agent`), and a turn-finished trigger dispatches the HEAD item only when its target matches the trigger's source (`ComposerModel.notePromptIdle(.shellPrompt)` from OSC-133;A ↔ `.shell`; `notePromptIdle(.agentTurnEnd)` from the type-27 `.done` edge ↔ `.agent`). Rationale: the old single-trigger design let prompts enqueued for a mid-turn Claude fall through to the shell after Claude exited — zsh then EXECUTED each English prompt, one per prompt (`rm …`-class hazard when a prompt begins with a real command name). A mismatched head HOLDS the whole queue (FIFO preserved, never skipped) and the strip shows a held-reason badge; the release is EXPLICIT — tap-to-edit the chip back into the Composer and send it deliberately. → `SlopDeskClaudeCode/PromptQueueModel.swift`, `Input/ComposerModel.swift`, `Pane/PromptQueueStrip.swift`
- ✅ **The presence-floor `.idle` is NOT "agent between turns".** In the default no-hooks config the host's only signal is the foreground watch, whose type-27 can never leave `.idle` (`ClaudeStatusMachine` presence floor) — treating that as "agent idle" made the enqueue kickstart type into a MID-TURN Claude. `LivePaneSession` now tracks `agentTurnSignalsVerified` — set on the first `.working`/`.done`/`.needsPermission`, which ONLY the authoritative hook/ctl paths can produce; sticky for the pane-session lifetime (the same PTY env keeps `SLOPDESK_SOCKET_PATH`, so a restarted claude in the same pane still reports) — and an agent pane is composer-idle ONLY when verified AND `.idle`/`.done`. An unverified agent pane holds the queue with the visible held reason; auto-dispatch never guesses. → `Workspace/Store/LivePaneSession.swift`
- ✅ **Hook events stamp the foreground-absence grace window; wrapper basenames never terminate a hook-authoritative status.** `ClaudePaneDetector.hook()` now stamps the same stickiness anchor the ctl `report` verb already had (renamed `lastAuthoritativeAt`), so the ~1 Hz foreground poll cannot wipe a hook-set `working`/`needsPermission` within the grace window when claude runs under a wrapper (the npm-installed `claude` bin is a `#!/usr/bin/env node` shebang → the PTY foreground basename is `node`, never `claude`). Additionally, while a hook/report-established status is live, an absence whose basename is a known wrapper (`node`/`npx`/`bun`/`deno`/`mise`, `ClaudeManifestMatcher.isLikelyWrapper`) NEVER terminates — covering quiet gaps longer than the window (idle between turns, long tool runs). A non-wrapper absence (zsh back in the foreground) past the window terminates as before, and a wrapper never LIFTS the presence floor (a random `node` dev server cannot light the agent dot). Accepted narrow staleness: a hard-killed wrapped claude followed <1 s by an unrelated node foreground keeps the stale status until the foreground changes or the next hook fires. → `SlopDeskHost/ClaudePaneDetector.swift`, `SlopDeskAgentDetect/ClaudeManifestMatcher.swift`
- ✅ **`agentHookStatus` (13) reports the LIVE hook-listener state, not just the settings.json marker.** The response payload is now 2 bytes: `[installed][listenerActive]`, where `listenerActive` is the REAL AF_UNIX bind state of the hostd hook listener (bound only when hostd was LAUNCHED with `SLOPDESK_AGENT_HOOKS=1` — the Settings toggle only reaches the sidecar on the NEXT hostd launch). The Agents card maps installed-but-inactive to a distinct `.installedInactive` state ("Installed — inactive" warning badge + the "start the host daemon with SLOPDESK_AGENT_HOOKS=1, then reopen panes" hint) instead of the false green "✓ Installed" that made the integration look enabled while every hook exited silently (`[ -z "$sock" ] && exit 0`). A 1-byte reply (no listener flag) conservatively decodes `listenerActive = false` — never a false green. → `SlopDeskHost/HostAgentActionPerformer.swift`, `Metadata/MetadataClient.swift`, `Workspace/Store/AgentHooksController.swift`, `Settings/SettingsView.swift`

## Outline-jump correctness + Outline tab merged into Info/Commands (2026-07-02)

> User-reported: the Outline "jump to prompt" landed on the wrong command; and the standalone Outline tab duplicated the Info tab's Commands list. One WIRE change (type-28 `commandBlock` grows a trailing-fixed `UInt32 promptOrdinal` before `cmdLen` — docs/20 updated, golden `blocksWireMessages` vectors regenerated; the 13 frozen keys untouched) + one UI re-scope (E9's Details-panel Outline tab is RETIRED; its affordances fold into the Info tab's Commands section).

- ✅ **Jump root cause (two independent count mismatches vs libghostty `scrollPrompt`, pinned v1.3.1).** (1) ghostty's downward `PromptIterator` starts at `viewport_top.down(1)` — the prompt ON the viewport-top row is never counted; after `scroll_to_top` a FRESH pane's row 0 IS prompt #1 (the shell's first prompt), so every top-anchored count was off by one (landed one command too new), and the client cannot know whether row 0 is a prompt. (2) ghostty counts EVERY `.prompt` row — one per primary OSC-133 `A` — including empty-Enter / Ctrl-C cycles the segmenter rightly discards (phantom-block fix), so a block-count-derived delta under-counts by each blockless cycle. **Fix: host-stamped `promptOrdinal` + a determinate anchor.** The segmenter counts primary `A` marks (`k=c`/`k=s`/`k=r` excluded; redraw-immune because `A` is precmd-emitted while only the in-`$PROMPT` `B` re-fires) and stamps each block; the client jump is `scroll_to_bottom` → `jump_to_prompt:-1_000_000` (a delta beyond the prompt count exhausts ghostty's upward iterator, which then moves to the LAST prompt found — the OLDEST retained prompt row, making "top row = prompt #1" an invariant) → `jump_to_prompt:(ordinal − 1)` (ordinal 1 = the anchor itself). Ordinal `0` (mid-stream join, no `A` seen) = graceful no-jump — never a mis-landing. ACCEPTED degradation: ghostty ring eviction of the earliest prompts shifts the landing by the evicted count (long-session edge). Pinned by `GhosttyScrollPromptModel` end-to-end replays (fresh-pane + empty-Enter scenarios FAIL on the old math — revert-confirmed), segmenter ordinal tests, and the wire codec exact-byte pins. → `CommandBlockSegmenter/Tracker`, `WireMessage±Encode/Decode`, `WorkspaceStore+Blocks` (`BlockJump`), docs/20, golden.
- ✅ **Outline tab RETIRED — merged into Info ▸ Commands (`BlockHistoryView`).** The Details panel is now Info | Git | Files. The Commands navigator absorbed the Outline's two distinctive affordances: a per-row jump-to-scrollback (trailing `arrow.right.to.line` button + a leading "Jump to Command" context-menu item, both routing to the shared ordinal-anchored `jumpToNavigatorBlockInActivePane`) and the relative first-seen stamp (`OutlinePresentation.relativeTime` on each row, ticking via a 30 s `TimelineView`). `OutlineView.swift` deleted; `DetailsPanelTab.outline`, the `view.detailsOutline` registry binding, and the `action.detailsOutline` palette row removed (`OutlinePresentation` STAYS — CommandNavigator/OpenQuickly reuse it). Retirement pinned negatively (`testDetailsBindingsSurfaceInTheViewDisplayGroup` / the palette-catalog test assert the outline ids are GONE). → `DetailsPanelTab`, `WorkspaceBindingRegistry`, `PaletteDataSource`, `InspectorColumn`, `BlockHistoryView`, `BlockRowView`.

## Git tab merged into Info (summary row + popup) + inspector action-feedback polish (2026-07-02)

> User-directed UX batch: the Details panel's standalone Git tab carried an unbounded changed-file list a narrow sidebar can never show well; the Working Directory path head-truncated away the volume/user components and its full-width "Copy Path" row wasted a line; the Commands output's "Render Markdown" toggle was never the right read for terminal output; and the copy actions gave no click feedback.

- ✅ **Git tab RETIRED — merged into Info as a one-row summary + a popup for the detail.** The Details panel is now Info | Files. The Info tab gains a GIT section (shown only when the pane's cwd is inside a repo): one row with branch, ahead/behind deltas, and a change count (`InfoTabFormatting.gitChangeSummary` — "clean" / "N changed"); clicking it presents `GitDetailsSheet`, a `AgentSessionHistoryView`-sized sheet hosting the FULL `GitStatusView` (status list + per-file diff overlay + refresh) — the changed-file list is unbounded, so it gets a window, not a sidebar tab. `DetailsPanelTab.git`, the `view.detailsGit` registry binding, and the `action.detailsGit` palette row removed; retirement pinned negatively alongside the Outline pins. → `DetailsPanelTab`, `WorkspaceBindingRegistry`, `PaletteDataSource`, `InspectorColumn`, `GitStatusView` (+`GitDetailsSheet`).
- ✅ **Working Directory row is RESPONSIVE, with the copy action inline.** `ViewThatFits`: full path → fish-style component abbreviation (`InfoTabFormatting.abbreviatedPath`, `/Users/dev/slop-desk` → `/V/L/W/o/slopdesk`; `~` survives whole, dot-dirs keep `.x`, the project-identifying LEAF is never shortened) → head-truncated abbreviation as the last resort. The Copy action moved from its own full-width row to a trailing icon on the path row. → `InspectorColumn` (`workingDirectoryLabel`, `InfoTabFormatting.abbreviatedPath`).
- ✅ **"Render Markdown" toggle REMOVED from the block-output header.** Terminal output renders coloured VT text (ANSIOutputStyler), one way — the opt-in Markdown re-render (`MarkdownText`) misread most outputs and duplicated the copy button's neighbourhood with a low-value control (`MarkdownText` STAYS — the agent transcript uses it). → `BlockOutputView`.
- ✅ **Click feedback on silent one-shot actions.** New `ConfirmFlashButton` (DesignSystem): runs the action, hands the label builder `confirming: true` for a 1.2 s beat (re-clicks re-arm via `.task(id: generation)` cancellation) — Copy Path / Copy Session ID / Copy Output flash a `Slate.Status.ok` checkmark; the git popup's refresh button yields to a spinner while its round-trip is in flight. → `ConfirmFlashButton`, `InspectorColumn`, `BlockOutputView`, `GitStatusView`.

## Web pane REMOVED (feature prune, 2026-07-02)

> Refocus (slopdesk's core = remote TERMINAL panes + REMOTE-GUI window streaming). The LOCAL `WKWebView` browser pane (E18, `PaneKind.web`) was a whole non-core vertical — its own leaf view, seam, normalizer, store ingress, dispatcher chord-yield, and drop-policy arms — and is deleted end-to-end.

- ✅ **`PaneKind.web` + `PaneSpec.webURL` RETIRED; decode bridges to `.terminal`.** The case, the additive `webURL` field (+ its Codable key), `WebLeafView`/`WebPaneModel`, the `WebPaneSeam` (`WebPaneDescriptor`/`WebNavigationGate`/`WebPaneController`/`WebPaneContext`/`WebRendererFactory`), `WebURLNormalizer`, `WorkspaceStore+WebPane` (`openWebPane`/`setPaneWebURL`/`setPaneWebTitle`), the app-target `WebPaneView` + its `WebRendererFactory` registration and the WebKit link in both xcodegen specs, and the `WorkspaceKeyDispatcher` web-chord YIELD (⌘[/⌘]/⌘⇧R/⌘F to a focused web pane) are all deleted. **The one no-backcompat exception:** a persisted `"web"` raw kind decodes to `.terminal` via the SAME bridge as the retired `"claudeCode"` (`PaneKind.legacyWebRawValue`), so an old workspace file never traps; the stale `webURL` key is decode-ignored. Pinned beside the claudeCode bridge test (`ClaudeKindRemovalTests.testLegacyWebRawValueDecodesToTerminal`). → `PaneSpec`, `PaneChooser`, `LivePaneSession`, `WorkspaceStore`, `PaneContainer`, `WorkspaceKeyDispatcher`, `AppMain`.
- ✅ **Drop policy: a dragged URL now only PASTES (Insert Path); the Open-In-Place / Split web cells are DISABLED.** `DropAction.openWeb`/`.splitWeb` + `WebPanePlacement` deleted; `DropActionResolver`'s URL arms return `nil` for `.openInPlace`/`.splitLeft`/`.splitRight` (`allowedZones(.url)` = `{insertPath}`). The terminal-rooted drop ingress (`openTerminalRooted`) is untouched; its store tests moved from the deleted `WebPaneStoreTests` to `OpenTerminalRootedStoreTests`. → `DropActionResolver`, `PaneDropReceiver`, `WorkspaceStore+Drop`.

## Multi-session switcher UI REMOVED (feature prune, 2026-07-02)

> Refocus (slopdesk's core = remote TERMINAL panes + REMOTE-GUI window streaming). The multi-session SWITCHER — the E19 WI-5 / A32 strip above the sidebar's TABS list — and every "New Session" entry point are deleted; the workspace is effectively single-session at the UI. The **Session domain type and the store's multi-session internals STAY** (tabs live inside a `Session`; `newSession`/`selectSession`/`closeSession`/`renameSession` remain for the agent control backend's `.newWindow`, session templates, close-window semantics, and persistence restore — a store that restores multiple persisted sessions still lands on the active one, there is just no UI to create or switch them).

- ✅ **`SessionSwitcherView` + `SessionRowModel` deleted; both `NavigatorColumn` mounts removed** (macOS VStack above the "TABS" header + the iOS leading `List` Section). The switcher-only rename/close/add affordances go with it.
- ✅ **The "New Session" command surface is GONE end-to-end:** `WorkspaceAction.newSession` (⌃⌘N) + the `session.new` binding row + the whole `Category.sessions` menu section, both routing arms (tree → `openChooserPane(.newSession)`, canvas → new-pane analogue), `PaneChooserContext.newSession`, the `action.newSession` palette row, the `new_session` config-name mapping, and `WorkspaceStore.newSessionDefault()`. ⌃⌘N is now UNBOUND (free for a future core verb). Pinned test sets updated (cheat-sheet categories 6 → 5, chord table, palette catalog, chooser landing/routing); `SessionRowModelTests` deleted.

## Agent input surfaces REMOVED (feature prune, 2026-07-03)

> Refocus (slopdesk's core = remote TERMINAL panes + REMOTE-GUI window streaming). The AGENT INPUT surfaces — the E12 Composer (⌘⇧E) + Prompt Queue (⌘⇧M), the E13 Send to Chat dialog (⌘⌃↩), the three E13 "Fork in Split/Tab" actions, and the E13 WI-4 Claude bottom bar — duplicated typing straight into the terminal, which is what the user actually does. They are deleted end-to-end. Agent SUPERVISION stays fully functional: Claude status badges (type 26/27 fold), attention jump (⌘⇧U), and **Peek & Reply (⌘⌥J)** — including its reply delivery (`PeekReplyFormatter` → `WorkspaceStore.sendPeekReply` → the per-pane PTY funnel) — are untouched.

- ✅ **Composer + Prompt Queue GONE end-to-end:** `ComposerModel` (+ `ComposerTurnSource`/`ComposerPaneContext`/`PromptQueueHold`), `PromptQueueModel` (SlopDeskClaudeCode), the WorkspaceStore+Composer extension (`ComposerProviding`/`ResolvedComposer`, pin/float resolution, `requestComposerInActivePane`/`requestPromptQueueInActivePane`), the client views (`ComposerBar`/`ComposerTextView`/`ComposerFloatPanel`/`ComposerSheet`/`PromptQueueStrip` + `PinnedComposerBar` and the iOS composer bottom sheet), `LivePaneSession.composer` wiring (incl. the OSC-133;A `onPromptIdle` queue trigger and the `.done`-edge agent dispatch), the per-pane pin persistence (`SettingsKey.composerMaxHeight`/`composerPinnedPaneIDs`, `TerminalPreferences.defaultComposerMaxHeightFraction`), the right-click "Paste and continue in Composer" (`Item.pasteToComposer` + `Context.hasComposer` + `onPasteToComposer`), and `RichPasteMarkdown` (composer-paste-only). **KEPT:** `InputBarModel`/`InputBoxModel`/`InputDedupRing` — the per-pane ordered-OUT funnel + B1 echo-dedup every keystroke and Peek & Reply ride.
- ✅ **Send to Chat GONE end-to-end:** `WorkspaceAction.sendToChat` (⌘⌃↩ unbound), `SendToChatModel`/`SendToChatContext`/`SendToChatSession`, `SendToChatDialog`, the OverlayCoordinator dialog state (`sendToChatVisible`/capture/sessions/`copyToPasteboard`), the `toggleSendToChat` threading (dispatcher / menu / iOS interceptor toggles / routing param), the store capture + delivery (`captureSendToChatContext`/`captureSendToChatLastOutput`/`agentChatSessions`/`sendChatMessage`/`sendChatToNewSession`), the context-menu row (`Item.sendToChat` + `Context.canSendToChat` + `onRequestSendToChat`), and the `action.sendToChat` palette row.
- ✅ **Fork in Split/Tab GONE end-to-end:** `WorkspaceAction.forkInSplitRight/.forkInSplitDown/.forkInNewTab` + the three `agent.fork*` registry rows, both routing arms (`performFork`), `ForkSessionDetector` + `LivePaneSession`'s fork/branch observation (`forkSessionID`/`consumeForkSessionID`), and the three `action.fork*` palette rows. The E13 WI-6 Resume plumbing that only these consumed goes too: `AgentResumeRouter`, `LiveAgentSessionProviding`/`liveAgentSessionID`, `liveAgentSessionIDs()`/`resumeAgentInNewTab` (Open Quickly's Agents pill keeps its own direct `claude --resume` injection).
- ✅ **The Claude bottom bar (AgentInputFooter) GONE:** `AgentInputFooterView`/`Coordinator`/`Action` + `FileExplorerModel` and the `TerminalLeafView` mount/wiring. `InputBarModel.richMode` stays (the retained `InputBar` view reads it).
- ✅ **Category taxonomy shrinks:** the registry `Category.agents` (its rows were composer/queue/send-to-chat/fork only) and the palette `PaletteCategory.agents` are removed; the menu bar and cheat sheet render Panes/Tabs/Focus/View. ⌘⇧E / ⌘⇧M / ⌘⌃↩ are now UNBOUND (free for future core verbs). Pinned test sets updated (cheat-sheet categories 5 → 4, chordLess set drops the three fork ids, E1 keymap stub pins, context-menu order); the feature-only suites (Composer*/PromptQueue*/SendToChat*/Fork*/AgentResume*/AgentInputFooter*/RichPasteMarkdown tests) are deleted.

## Recipes + Snippets REMOVED (feature prune, 2026-07-03)

> Refocus (slopdesk's core = remote TERMINAL panes + REMOTE-GUI window streaming). The E16 RECIPES vertical (save/replay workspace layouts+commands as `.slopdeskrecipe` files: builder, TOML codec, trust store, replay machine, library scan, save/open/trust sheets, replay HUD, `open-recipe` control verb + `slopdesk open` CLI) and the SNIPPETS vertical (saved command macros + `@alias` at-prompt auto-expansion: the `Snippet` model, palette sources, value-entry sheet, snippet editor, `SnippetAliasExpander`, reserved vars) are deleted end-to-end — code, tests, settings, and every consumer.

- ✅ **Domain/Recipe/ + Snippet.swift deleted wholesale** (`Recipe`/`RecipeBuilder`/`RecipeTOMLCodec`/`RecipeTrust`/`RecipeReplayMachine`/`InteractiveCommandMatcher`/`PortablePaths`/`SnippetAliasExpander`/`ReservedSnippetVars`), plus `RecipeLibrary`, `WorkspaceStore+Recipes`/`+Snippets`, the whole ClientUI `Recipes/` directory, `SnippetEditorSheet`, `SnippetPasteboardiOS`, and every recipe/snippet test suite. **KEPT: `SendKeysParser`** — the tmux-style `<Token>` → bytes send-keys primitive lived in `Snippet.swift` but backs launch presets, session templates, block re-run, drops, and the CLI `pane send-keys`; it moved verbatim to `Domain/SendKeysParser.swift` (tests moved to `SendKeysParserTests`).
- ✅ **Persistence: `Workspace.snippets` (v9) + `TreeWorkspace.snippets` (v10/11) fields removed, NO schema bump** (no-backcompat directive): the stale `snippets` key decode-ignores on both shapes; the per-collection `maxItems` guards and merge caps drop their snippet terms. Export/import (canvas + tree) no longer carries snippets.
- ✅ **Command surface GONE end-to-end:** `WorkspaceAction.saveRecipe/.openRecipe` (+ both routing arms and the display-less ⌘S alias chord — ⌘S is now UNBOUND), `WorkspaceCommand.manageSnippets/.runLastSnippet` (⌥⌘R unbound), the File ▸ Recipe menu + Save Snippet… row, `RecipePaletteSource`/`SnippetPaletteSource` mixer sources, the Open-Quickly **Recipes pill** (`OpenQuicklyFilter.recipes`, `.recipe` kind, `.openRecipe` act — the pill ring is All/Opened/Recent/Folders/Agents/Current again, mirroring the E11 SSH structural cut), the in-pane `RecipeReplayHUD` mount, the `recipeSheets` app modifier + `snippetEditorPresented`, and Settings ▸ **Recipes** (taxonomy 9 → 8 sections; the `recipes.replayMode.*` / `recipes.snippetAutoExpand` keys + the `RecipeReplayMode` Defaults bridge are gone — stale persisted keys are simply orphaned).
- ✅ **Control/CLI surface GONE:** the `open-recipe` NDJSON verb (protocol method + params + dispatcher arm + backend requirement + `WorkspaceControlBackend` impl) and the `slopdesk open <recipe>` subcommand.
- ✅ **Terminal seams unwound:** `TerminalViewModel.onPromptReturn` (its ONLY consumer was the recipe-replay shell-handoff resume) + `snippetExpander`/`expandSnippetAlias()`/`isAtShellPrompt` and the ghostty surface's bare-Tab/Space expansion branch; the OSC-133;A ingest loop keeps feeding the mode tracker only.

## Floating panes REMOVED (feature prune, 2026-07-03)

> Refocus (slopdesk's core = remote TERMINAL panes + REMOTE-GUI window streaming). The zellij-style FLOATING/scratch overlay panes (P5a domain + E21 WI-6 renderer: float/embed toggle, floating spawn, movable+resizable overlay cards over the tiled tree) are non-core and deleted end-to-end — tree model, render model, store wrappers, actions/chords, palette/menu rows, renderer, and every test. This reverses the "revive `Tab.floatingPanes`" decision above; the tiled split tree is the ONLY pane layout again.

- ✅ **Tree model:** `Tab.floatingPanes` removed (`allPaneIDs()`/`contains` are tree-only again — the methods survive); `PaneSpec.floatingFrame` removed. NO schema bump (no-backcompat directive): both stale keys decode-ignore; a persisted workspace that still names floating panes drops them as orphan specs via `normalizingSpecs()` on load (the tiled tree restores intact — floats are NOT re-tiled).
- ✅ **Pure ops GONE:** `WorkspaceTreeOps.toggleFloating`/`spawnFloating`/`raiseFloating`/`moveFloating`/`resizeFloating`/`clampFloatingFrame`/`defaultFloatingFrame`/`floatingMinSize` + the `closePane` floating fast-path. `SplitTreeRenderModel` lost `floatingLeaves`/the `floating:` layout arg/`CompositorLeaf.isFloating` — the compositor list is visible tiled leaves + zoom-hidden leaves only (the zoom keep-mounted invariant is untouched).
- ✅ **Store wrappers GONE:** `floatingPanePairs`/`toggleFloatActivePane(...)`/`spawnFloatingPane(...)`/`moveFloating`/`resizeFloating`/`closeFloating`/`embedFloating`/`floatingViewportBounds`; `focusPaneTree` no longer z-raises; `updateFloatingBounds` renamed `updateContainerBounds` (it only feeds the directional-focus geometry fallback now). `PaneChooserContext.floating` removed.
- ✅ **Command surface GONE:** `WorkspaceAction.toggleFloat` (⌥⌘F) + `.spawnFloating` (⌃⌘⇧F), both binding rows (`pane.toggleFloat` "Float Pane" / `pane.spawnFloating` "New Floating Pane"), both routing arms (tree + canvas) — the registry-driven Pane menu + palette rows disappear with them. ⌥⌘F and ⌃⌘⇧F are now UNBOUND; ⌃⌘F stays reserved for the system Toggle Fullscreen (pin kept).
- ✅ **Renderer:** `FloatingPaneCard.swift` (`CompositorPaneCard`) deleted — `SplitContainer` mounts `PaneContainer` directly per compositor leaf (same `.id(PaneID)` keying, same zoom-hidden opacity flip, no `floatZBase` band). Tiled rendering is structurally identical (the card's tiled mode was already chrome-less).

## Theme editor/import + workspace export/import REMOVED (feature prune, 2026-07-03)

> Refocus (slopdesk's core = remote TERMINAL panes + REMOTE-GUI window streaming). The E15 THEME EDITOR/IMPORT surface (the Appearance swatch grid + Duplicate/Edit/Open-Themes-Folder/Import-Theme… affordances, the custom `.slopdesktheme` folder scan at `~/.config/slopdesk/themes/`, the 5-format importers, the hand-rolled theme TOML parser, the `theme import` CLI/control verb) and the E7 WI-4 WORKSPACE EXPORT/IMPORT surface (Settings ▸ Advanced ▸ Workspace, the File menu items, the portable `.slopdeskworkspace` envelope) are deleted end-to-end — code, tests, settings rows, palette rows, and every consumer. **Built-in themes and the Settings ▸ Appearance picker STAY** (dual-slot follow-OS resolution included); themes are BUILT-IN-ONLY now.

- ✅ **Theme leaf (SlopDeskVideoProtocol) GONE:** `ThemeDocument`, `ThemeTOMLParser`, `ThemeImporters`, `ThemeLibrary` (folder scan / serialize / write / importFile / legacy-extension rename), and `ThemeRef` (built-ins need no slot-reference enum). `ThemeResolution.activeRef(…) -> ThemeRef` became `activeBuiltinID(…) -> String`; `AppearancePreferences.customLightSlug`/`customDarkSlug` removed with NO migration (no-backcompat: stale persisted keys decode-ignore; a slot that pointed at a custom theme falls back to its built-in choice). `TerminalConfigBuilder` now owns its own `paletteCount`/`isValidHex` validators (the palette-override seam is unchanged — built-in themes still pin the 16-colour ANSI palette + selection).
- ✅ **ClientUI GONE:** `ThemeEditorView` (swatch grid + edit/duplicate/import UI), `SlateTheme(document:)` (+ its `rgb24`/`mix`/`color` helpers), `ThemeCatalog`'s custom half (`customThemes`/`reloadCustom`/`customDocument`/`resolve` + the injectable scan seam — the catalog is now a static built-in list + id lookup), `ThemeStore.resolveCustomDocument`, the Settings picker's custom-theme section (`ThemeSelection` enum → plain `ThemeChoice` binding), and the FirstLaunch custom-slug arms.
- ✅ **Palette rows for theme FILES GONE:** `action.reloadConfig` ("Reload Config") + `action.openThemeFile` ("Open Theme File") — `PaletteAction.reloadConfig`/`.openThemeFile`, the `OverlayCoordinator.reloadConfig`/`openThemeFile` closures + run arms, and the app-side bindings. **KEPT: the "Switch Theme" row** (cycles the built-ins live); the Settings ▸ Advanced ▸ Config File "Reload Config" BUTTON and the CLI `config reload` both stay (they reload the keybind config, not theme files).
- ✅ **Control/CLI surface:** the `theme-import` NDJSON verb (protocol method + params + dispatcher arm + backend requirement + `WorkspaceControlBackend` impl) and the `slopdesk theme import` subcommand are GONE; `theme list` stays and now enumerates built-ins only. `config set theme <name>` accepts built-in ids / `ThemeChoice` raw values only (an unknown name is still an honest reject).
- ✅ **Workspace export/import GONE end-to-end:** `WorkspaceTransferDocument.swift` (the `FileDocument` + UTType + Advanced ▸ Workspace section + `WorkspaceFileCommands` File-menu items + the `\.workspaceStore` environment slot), `WorkspaceStore.exportWorkspaceData()`/`importWorkspace(_:mode:)`/`WorkspaceImportMode` (canvas + tree arms, `WorkspaceStore+Transfer.swift`), the `WorkspaceTransfer` envelope codec, `TreeWorkspace.withFreshIdentities()` + `SplitNode.withFreshSplitIDs()` (import-only re-mint helpers), and `WorkspaceStore.uniqueName` (merge-only). **KEPT: the load-bound cap** — `WorkspaceTransfer.maxItems` moved to `WorkspacePersistence.maxItems` (the on-disk load()/loadTree() ceilings are persistence hardening, not transfer).
- ✅ **Textual dependency DROPPED:** its only consumer was `MarkdownText` (the large-doc-guarded Markdown seam), which lost its last view consumer when the right-sidebar inspector was removed (6de70aa) — `MarkdownText.swift` + tests deleted, `gonzalezreal/textual` removed from Package.swift/resolved.
- ✅ **Tests:** feature-only suites deleted (ThemeDocument/ThemeTOMLParser/ThemeImporters/ThemeLibrary/ThemeEditorDuplication/ThemeImportSwitch/SlateThemeFromDocument/WorkspaceTransfer/TreePersistenceFix/MarkdownText); pinned sets updated (ThemeResolution → `activeBuiltinID`, ThemeCatalog → built-in round-trip + ordered-list pin, ThemeStore/FontScopeResolver/PreferencesStoreApply drop custom-slug cases, palette catalog drops the two rows, ClientControlDispatcher drops `theme-import`, CrossCuttingFix keeps the preset-switch pins, persistence maxItems pins repoint).

## Single workspace window + keyboard/IME fixes (fix batch, 2026-07-03)

> The workspace is a documented SINGLE-window model: one WindowGroup window + the stock Settings scene. The whole macOS app wiring (`store` / `keyDispatcher` / `WeakWindowBox` / the close gate / the control socket) is app-wide singleton state, so the stock SwiftUI File ▸ New Window item minted a SECOND workspace window over the SAME store — whichever window's introspect hook fired last owned `windowBox`, chords intermittently died in the window being typed in, and the ⌃A prefix leaked into remote-GUI panes. New Window is removed and the key-window gate hardened; two smaller keyboard items ride along.

- ✅ **File ▸ New Window REMOVED** — `CommandGroup(replacing: .newItem) {}` on the WindowGroup (`.newItem` carries only the New-Window item for a plain WindowGroup; the rest of the File menu is untouched). A second workspace window is no longer mintable, so the app-wide singletons keep their 1:1 window mapping. → `SlopDeskClientApp`.
- ✅ **Key-window gate is a pure IDENTITY predicate** — `workspaceWindowIsKey(captured:keyWindow:)`: the dispatcher owns chords ONLY while the introspect-captured workspace window IS `NSApp.keyWindow`. The old `window.map(\.isKeyWindow) ?? true` defaulted a nil capture (pre-introspect, or the WEAK box going stale after the window closed) to "workspace is key", which let a stale box swallow chords while Settings was frontmost. Belt+braces with the New-Window removal; pinned headlessly with `AnyObject` fakes (`DispatcherKeyWindowGateTests`). → `SlopDeskClientApp`, `WorkspaceKeyDispatcher`.
- ✅ **IME composition CANCELLED on pane blur** — `GhosttyLayerBackedView.resignFirstResponder` now runs `unmarkText()` (clears the marked-text mirror + republishes the empty ghostty preedit) and `inputContext?.discardMarkedText()` before resigning, so a mid-Telex/Japanese composition never strands its preedit in the abandoned pane nor double-lands staged keystrokes on refocus. Guarded/idempotent; nothing is committed to the PTY. App-target-only file (compile-gated by the app build; HW verify: compose `vieej`, switch pane, return). → `GhosttyTerminalView`.
- ✅ **"Prefix armed" chip (NEW, minimal)** — when the tmux-style ⌃A prefix arms, a tiny bottom-leading chip (`⌃A prefix`, Slate tokens, hit-test-transparent) shows until the arm resolves: a bound follow-up FIRES it away, an unbound follow-up / double-tap disarm it, and the escape TIMEOUT clears it via a dispatcher expiry task (the machine is clock-lazy, so the dispatcher now schedules the expiry edge itself). Seam: `WorkspaceKeyDispatcher.onPrefixArmedChange` → `OverlayCoordinator.setPrefixArmed` (`prefixArmed` `@Observable`) → `OverlayHostView`'s `PrefixArmedChip`. Transitions pinned headlessly (`PrefixArmedIndicatorTests`); iOS keeps no chip (its per-surface interceptor arms are pane-local — follow-up if wanted).

## Command jump chunked past i16 + Navigator row actions (fix batch, 2026-07-03)

> The shared ordinal-anchored block jump (`BlockJump`, used by the Command Navigator per-row jump, the Commands panel, and Jump-to-Failed) must land on the RIGHT prompt even for large prompt ordinals, and the ⌃⌘O Command Navigator now offers per-row Re-run + Copy-Output so a command can be acted on without leaving the overlay.

- ✅ **Downward step is CHUNKED to fit ghostty's i16 binding parameter** — `BlockJump.toPromptOrdinal` emitted the whole `ordinal − 1` delta as ONE `jump_to_prompt:<n>`, but ghostty parses that parameter as `i16` (`Binding.zig`, pinned v1.3.1); once the ordinal passed 32768 (a long-lived detached session — every Enter increments the host-stamped prompt ordinal) the step overflowed i16, failed the action-string parse, and silently no-opped the whole binding, so the jump landed on the anchor (oldest prompt) instead of the target. The step is now split into in-range hops of at most `BlockJump.maxStep` (32000): each positive `jump_to_prompt` re-counts from the new viewport-top's `down(1)`, so consecutive hops COMPOSE to the full delta and land the exact prompt (chunking lands true where saturation would land short). Small ordinals are byte-identical to before (one hop ≤ maxStep). The anchor delta (`reAnchorDelta`) was already clamped to −32000 in 84b2cf3 for the same i16 reason. → `WorkspaceStore+Blocks.swift`; pinned by `WB3BlockRoutingDispatchTests` (ordinal 40000 splits to in-range hops summing to 39999; the maxStep boundary is a single hop, one past it splits).
- ✅ **A binding no-op is now SURFACED at default log level** — when a jump's `scroll_to_bottom` / anchor / any step returns `false` from a real surface (a rejected delta, or a headless/placeholder surface), `BlockJump` logs at `Logger` default level (`com.slopdesk.workspace`/`blocks`), not only behind `SLOPDESK_BLOCKS_DEBUG` — a silently-failed navigator / Jump-to-Failed jump is diagnosable in the field without setting the debug env. → `WorkspaceStore+Blocks.swift`.
- ✅ **Command Navigator per-row Re-run + Copy Output (⌃⌘O overlay)** — the selected/hovered row now shows two trailing affordances: Re-run (verbatim, injection-safe, via the shared `WorkspaceStore.reRunCommandInActivePane(_:)` — closes the overlay since output goes to the live shell) and Copy Output (VT-stripped plain text via the new `WorkspaceStore.copyBlockOutputInActivePane(index:onResult:)`, the SAME wire type 15 → 29 request path the terminal context menu's "Copy Command Output" uses — stays open, the view owns the `NSPasteboard`/`UIPasteboard` write since the headless core owns no clipboard). Keyboard: plain ↩ still jumps + closes; ⌘↩ re-runs the selection; ⌘C copies the selection's output (both guarded on the ⌘ modifier so unmodified keys still reach the search field). → `CommandNavigatorView.swift`, `WorkspaceStore+Blocks.swift`; store routing pinned by `WB3BlockRoutingDispatchTests` (copy routes to the active model for the given index + resolves from the reply; an empty reply resolves `nil`). App-target/renderer view changes are compile+manual-verify (⌃⌘O row buttons + ⌘↩/⌘C).

## Sidebar rows: path-searchable git rows + inline rename + git-line staleness (fix batch, 2026-07-03)

> The rail sidebar was redesigned this cycle (c930f05): a terminal row's line 1 is its cwd FOLDER NAME, line 2 is the git line (branch ↑/↓ · N changed) when the cwd is a repo, else the plain cwd. Three gaps fell out of that redesign — a repo row lost its path (unsearchable, and two same-named worktrees looked identical), the "Rename Pane/Tab" command had no consumer after the old `TabBarView` was deleted, and the git line went stale on an idle pane. This batch closes all three with pure, headlessly-pinned store/builder logic.

- ✅ **Repo rows stay path-searchable + same-named worktrees disambiguate (C3 BUG A)** — `RailRow` gained a hidden `cwd` key (a terminal pane's `lastKnownCwd`, `nil` for a video pane): `RailRowsBuilder.filtered` now matches title + subtitle + `cwd` + `processLabel`, so a git row (whose visible subtitle is the git line, not the path) is searchable BY PATH again. The row also carries `.help(cwd)` as a tooltip. When two VISIBLE rows collide on a folder-name title, `RailRowsBuilder.disambiguated` prefixes the parent path segment (`feature-a/myapp` vs `feature-b/myapp`) — only folder-derived titles are rewritten (an explicit rename that collides is left verbatim), only when a distinct parent exists. → `RailRowsBuilder.swift`; pinned by `RailRowBuilderTests` (path filter with git line present, process-label filter, collision→parent-qualify, unique title untouched, explicit-rename untouched, the pure `parentQualifiedTitle` helper).
- ✅ **"Rename" restored on the current sidebar (C3 BUG B)** — the palette/⌘R `requestRenameActivePane()` set `pendingTabRename` but nothing consumed it after `TabBarView` was deleted. `RailRow` now exposes `isEditing` (`store.pendingTabRename == tab.id` AND the pane is that tab's representative/active pane — one editing row per pending tab), which `SlateTabRow` (macOS) / the iOS list row swap for a self-focusing `TextField`: commit on Return/blur via the new `WorkspaceStore.renamePane(_:to:)` (writes the pane spec title so `rowTitle`'s precedence surfaces it, winning over the folder name; a blank commit no-ops), cancel on Escape (macOS `onExitCommand`). A "Rename" row was added to the sidebar row context menu (`store.requestRenameTab(_:)`) so it is mouse-reachable on a background tab too. → `RailRowsBuilder.swift`, `SlateTabRow.swift`, `NavigatorColumn.swift`, `WorkspaceStore.swift`; pinned by `RailRowBuilderTests` (pending→editing on representative row only, commit wins over folder name, clear closes) + `SidebarGitAndRenameStoreTests` (request/clear, renamePane trims + no-ops blank, active-tab arm). The `TextField` swap itself is app-target/manual-verify.
- ✅ **Git line self-heals instead of freezing (C3 BUG C)** — the connect-edge populate was guarded `paneGitSummary[id] == nil`, so after the first populate an idle pane (no command, no cd) NEVER refreshed — stale across reattach and blind to sibling-pane commits in the same repo. FIX, carefully bounded so the ~3 s RTT snapshot never becomes a git-status poll: (a) a genuine reconnect edge always refreshes — new `ConnectionViewModel.onReconnected` (fired only on `.reconnected`, distinct from the RTT-snapshot `onResumeIdentitySnapshot`) → `refreshGitSummary`; (b) the snapshot edge re-fetches ONLY the ACTIVE pane and ONLY when its cached line is older than `gitSummaryStaleWindow` (60 s), tracked by a new `paneGitFetchedAt` clock (pruned with the summary); (c) a landed fetch FANS the summary out to every live pane sharing the same `paneGitToplevel` (a same-repo sibling), each dirty-guarded — an empty toplevel ("no repo") never fans; (d) a context-menu "Refresh Git Status" row (`store.refreshGitSummary(for:)`) for on-demand re-probe. A non-repo pane still stops polling (its summary caches `hasRepo:false`). → `WorkspaceStore.swift`, `ConnectionViewModel.swift`; pinned by `SidebarGitAndRenameStoreTests` (populate-once, skip-fresh-active, refetch-stale-active, skip-stale-background, fetchedAt stamp, same-repo fan-out, no cross-repo fan-out, fetchedAt prune).

## Settings correctness: pacer label, raw overrides reach the host, FEC-k seed (fix batch, 2026-07-03)

> Three Settings-pane correctness gaps: the pacer picker's default option lied ("Default (deadline)" while the runtime default is present-on-arrival), the free-text "Raw overrides" box only touched the CLIENT's in-process overlay so host-only knobs typed there never reached the daemon, and the FEC group-size stepper seeded a value that disagreed with the consumer's fallback.

- ✅ **Pacer default option relabelled to the truth** — the nil/unset `Mode` tag now reads "Default (on arrival)" (was "Default (deadline)"). `VideoWindowPipeline` resolves an absent `SLOPDESK_PACER` to `deadlineMode=false` (present-on-arrival — the 2026-06-16 latency-first default); the label now matches. The `CLAUDE.md` flag table's `SLOPDESK_PACER` row was corrected the same way (default = present-on-arrival; `=deadline` opts INTO the deadline pacer). → `SettingsView.swift`, `CLAUDE.md`. App-target/SwiftUI label (compile + manual-verify).
- ✅ **Raw overrides now reach the HOST daemon via the sidecar** — `applyVideoAndAgent` folded `rawOverrides` into the client's in-process `EnvConfig.overlay`, but `writeSidecar` serialised only the typed `video`/`agent` fields, so a HOST-only knob typed in the free-text box (the box's help text promises it works) was silently client-only. `EnvBridge.VideoSidecar` gained a `rawOverrides: [String: String]` field: it round-trips in `video-prefs.json`, folds LAST in `toEnv()` (a raw override beats the typed field for the same key — last-wins, mirroring the live overlay), and the host's `loadDefaultSidecarIntoEnvConfig` (via `loadSidecar` → `toEnv()`) applies it under the same gap-fill precedence (a real env var / earlier overlay entry still wins). Decode is OPTIONAL (`decodeIfPresent ?? [:]`) so a stale sidecar written before the field existed still loads (→ empty) rather than decode-failing the whole file ([[rwork-no-backcompat]] new-optional-field discipline). → `EnvBridge.swift`, `PreferencesStore.swift`; pinned by `EnvBridgeTests` (raw round-trip + last-wins precedence + old-sidecar-without-field decodes) and `PreferencesStoreApplyTests` (raw overrides land in the on-disk sidecar).
- ✅ **FEC group-size (k) stepper seeds the consumer's actual default** — the "Group size (k)" stepper seeded `5` (was `8`), matching `AdaptiveFECPolicy.defaultK` (5), so flipping the field ON and leaving it at the seed no longer silently changes `k` from the runtime default. → `SettingsView.swift`. App-target/manual-verify.
- ✅ **Dead `canvas.*` SettingsKey constants removed** — `snapPanes` / `snapGrid` / `showGrid` / `nonOverlap` had zero readers after the canvas/floating-pane verticals were pruned (only `defaultPaneKindKey` survives, still backing `Defaults[.defaultPaneKind]`). Constants + their `SettingsKeyTests` pins deleted. → `SettingsKey.swift`, `SettingsKeyTests.swift`.

## Video input: Caps Lock is a toggle, modifier releases are loss-resilient, manual release escape hatch (fix batch, 2026-07-03)

> Two H bugs in the GUI-video input path plus one small escape hatch, all riding the EXISTING wire messages (no wire change; golden corpus untouched). The shared held-modifier keyCode vocabulary now lives in `SlopDeskVideoProtocol.InputModifierKeys` (left/right ⌘⇧⌃⌥ + fn; Caps Lock 57 deliberately excluded) so client policy and host dedup can never disagree.

- ✅ **Caps Lock excluded from the modifier latch/resync/release machinery (C5 BUG A)** — the 2026-07-02 modifier-latch fix treated keyCode 57 like a held modifier: focusing a GUI pane with local Caps ON synthesized a Caps key-down on the host (`InputInjector.postKey` posts virtualKey 57 → TOGGLES remote Caps) and blur synthesized the "release" (toggles again) — remote Caps flipped on every focus/blur. Caps is a TOGGLE, not a held key: `ModifierLatchTracker.note` now ignores 57 (release lists can never contain it) and `heldModifierKeyCodes` (the refocus resync set) no longer includes it. Genuine `flagsChanged` Caps edges still forward 1:1 while focused. → `VideoClientSessionLogic.swift`, `VideoWindowView.swift`; pinned by `ModifierLatchTrackerTests.testCapsLockEdgesAreNeverLatched` + `FlagsChangedModifierTests.testHeldModifierKeyCodesExcludeCapsLock` (both proven failing pre-fix).
- ✅ **Modifier key-UP now rides the mouseUp-parity redundancy, deduped on the host (C5 BUG B)** — `sendKey` fired ONE datagram per key event, so a lost modifier release permanently latched the flag on the host's shared `hidSystemState` source (every later plain scroll became ⌘-scroll) until the user happened to re-press it. CLIENT: a held-modifier key-up is built once and sent `redundantUpCount` (3)× — the same burst as `sendMouseUp`; downs, ordinary keys, and Caps stay single-send (pure policy `SlopDeskVideoClientSession.keySendCount`, pinned by `InputKeyRedundancyTests`). HOST: `InputButtonBalance.plan` grew a `heldModifierKeys` set mirroring the button dedup — the FIRST release posts, duplicates/orphans are suppressed, a down for an already-down modifier is a no-op; ordinary keys (auto-repeat = identical downs) and Caps pass through verbatim (pinned by the new `InputButtonBalanceTests` modifier cases, proven failing pre-fix). Same bytes each copy, so the redundancy can never become a spurious extra modifier edge. → `SlopDeskVideoClientSession.swift`, `VideoSessionLogic.swift`, `InputModifierKeys.swift` (new, pure).
- ✅ **"Release Stuck Input" palette command (NEW, chord-less)** — the manual escape hatch for a host still holding input despite the automatic paths (e.g. all 3 release copies lost): registry row `view.releaseStuckInput` (View category, `chord: nil` — the `view.readOnly` idiom) → `WorkspaceStore.releaseStuckInputInActivePane()` → the ACTIVE pane's `PaneSessionHandle.releaseStuckInput()` (default no-op; `LivePaneSession` forwards to `RemoteWindowModel.releaseStuckInput()`) → the video view's published release sink synthesizes a key-UP for EVERY held-modifier keyCode + a mouse-UP for all three buttons at the pane centre, through the existing send paths (so each release itself rides the redundancy, and the host suppresses the no-op ones). The sink is READ-ONLY-GATED at the seam exactly like paste-as-keystrokes (`videoLeaf` binds nil while locked) and cleared on teardown. → `VideoWindowSeam.swift`, `RemoteWindowModel.swift`, `GuiLeafView.swift`, `VideoWindowView.swift`, `AppMain.swift`, `WorkspaceBindingRegistry.swift`, `WorkspaceBindingRouting.swift`, `WorkspaceStore+RemoteWindow.swift`, `PaneSessionHandle.swift`, `LivePaneSession.swift`; pinned by `TreeCommandRoutingTests` (chord-less row + active-pane-only routing), `RemoteWindowModelTests` (sink drive + inert-without-sink), `ReadOnlyStoreTests` (seam withholds the sink while read-only). HW verify pending: stick a modifier with induced loss, fire the palette row, confirm the host unlatches.

## Video host lifecycle: VD termination disconnects cleanly, DIALOG-EXPAND rebuild recovers, crash sidecar restores parked windows (fix batch, 2026-07-03)

> Three host-side lifecycle gaps in the GUI-video path, all "silent freeze / stranded window" class. No wire change (the host→client `.bye` the client FSM already handles carries all of it; golden corpus untouched). Per the video discipline, every DECISION is a pure, headlessly-pinned policy; the SCK/VT/AX side effects stay thin in the actor/daemon and are HW-verify.

- ✅ **VD termination now disconnects the affected sessions instead of freezing them (C6 BUG A)** — when WindowServer terminates the virtual display (sleep/wake, GPU reset, fast-user-switch), the daemon used to only `restoreAll()` the parked window frames; every live session whose window was PARKED on the dead VD kept capturing it — a silent client freeze with no bye and no reconnect. FIX: `VirtualDisplay.onTerminated` now computes the affected lanes via the pure `VirtualDisplayTerminationPolicy.channelsToDisconnect(parkedChannels:liveChannels:)` (parking-ledger channel bindings ∩ registry live-lane set — TARGETED: unparked 1× sessions survive untouched) and for each sends a host→client `.bye` (×2 — one unacked UDP datagram) then `retireAndStop`s + unparks it, then `restoreAll()`s the remainder; the client's existing disconnect/reconnect UI engages and its fresh hello re-mints. Snapshot inputs: new `WindowParkingLedger.parkedChannelIDs` / `WindowParkingManager.parkedChannelIDs`, `VideoMuxSinkTable.channelIDs` / `VideoMuxSessionRegistry.liveChannelIDs`. Re-park stays fail-soft (`handleTermination` clears `displayID` BEFORE notifying, so a concurrent mint falls back to 1×). → `VirtualDisplayRecoveryPolicy.swift` (new), `WindowParkingLedger/Manager`, `VideoMuxSessionRegistry`, `slopdesk-videohostd/main.swift`; pinned by `VirtualDisplayTerminationPolicyTests` + the ledger/registry snapshot pins.
- ✅ **Lazy VD re-create on the next park request (C6 BUG A, part 2)** — the VD was created once for the daemon lifetime, so after a termination every later pane stayed soft at 1× until a daemon restart. The first park request that finds `displayID == 0` now re-creates the VD on the SAME held `VirtualDisplay` instance (its state was cleared by the termination handler; the launch geometry/fps ride a `VDRecreateContext`, armed only when the launch-time create succeeded), throttled by the pure `VirtualDisplayRecreatePolicy` + `VirtualDisplayRecreateGate` (single-flight — `applySettings:` blocks up to ~10 s — plus a 30 s cooldown so a host whose WindowServer keeps killing VDs degrades to 1× instead of stalling every mint). Losing/throttled mints capture 1× and a later hello retries. → `VirtualDisplayRecoveryPolicy.swift`, `main.swift`; pinned by `VirtualDisplayRecreatePolicyTests` (policy + gate).
- ✅ **DIALOG-EXPAND rebuild failure no longer strands a dead `.streaming` session (C6 BUG B)** — `applyCaptureRegion` stops the OLD capturer before starting the union-region one; if that start threw, the catch left `capturer = nil / encoder = nil` with the session still `.streaming` — pane frozen forever, no recovery (contrast `applyResize`'s `rollBackWindow` + `restartOldSizeCapture`). FIX: the pure `CaptureRegionFailureRecovery` ladder — try union → `recoverPlainWindowCapture` rebuilds a PLAIN window-frame capturer (stream degrades to the un-expanded window; window-origin input/cursor mapping restored, degraded size resizeAck'd frame-gated, stale contentMask cleared) → if even the fallback fails, `.bye` (×2) + `stop()` (a visible disconnect the client's reconnect UI handles beats a silent freeze; the lane retire also unparks the window). Supersede/teardown races abandon (mirroring the resize path's FIX #1/#5 guards). → `CaptureRegionRecovery.swift` (new), `SlopDeskVideoHostSession.swift`; pinned by `CaptureRegionFailureRecoveryTests`; the SCK failure path itself is HW-verify.
- ✅ **Daemon crash no longer strands parked windows — the sidecar the shutdown comment promised now exists (C6 BUG C)** — clean shutdown restores parked windows, but a SIGKILL/crash left them shrunk + off-screen with nothing to recover them at next launch. FIX: `WindowParkingManager` mirrors the parked SET to a schema-versioned JSON sidecar (`<AppSupport>/SlopDesk/parked-windows.json`, one entry per DISTINCT window — windowID/pid/original frame) on every recorded park / last-lane unpark / drain (empty ⇒ file deleted, so a clean exit leaves no journal); the next launch reads any leftover file BEFORE creating a fresh VD, deletes it FIRST (one-shot), and AX-restores only windows that (a) still exist with the SAME owner pid (CGWindowIDs are per-boot and reusable) and (b) the pure `StrandedWindowRestorePolicy` deems stranded — not near the recorded original AND intersecting NO current display; a window WindowServer/the user already re-homed is never yanked, and an empty display read fails SOFT (no move on uncertainty). No-backcompat: version mismatch / malformed JSON ⇒ decode-`nil` ⇒ ignored. → `WindowParkingSidecar.swift` (new), `WindowParkingManager.swift`, `main.swift`; pinned by `WindowParkingSidecarTests` (codec round-trip, garbage/version-mismatch → nil, all four predicate classes) + `WindowParkingLedgerTests.testSidecarEntriesOnePerDistinctWindowSorted`; the AX/CGWindowList reads are HW-verify.

## Remote-window pane UX: reachable paste-as-keystrokes + link-health / stall / edge-hint models (fix batch, 2026-07-03)

> The remote-GUI (PATH 2 video) pane had a fully-implemented but UNREACHABLE clipboard-paste path, plus three invisible-affordance gaps the client can surface from state it already tracks. This batch wires the paste affordances end-to-end (client-side) and lands the three improvements as pure, headlessly-pinned policy/formatting models (their app-target render/stat-plumbing is the noted HW-verify step). No wire change (golden corpus untouched).

- ✅ **Paste as Keystrokes is now REACHABLE in a remote-GUI pane (C7 BUG)** — `RemoteWindowModel.pasteAsKeystrokes(_:)` (paced `CGEvent`-replay typing that reaches a sudo / SecurityAgent secure field) + `WorkspaceStore.clipboardRing` were both live but had NO consumer, so a plain ⌘V into a GUI pane forwarded a raw Cmd+V that pastes the HOST clipboard — LOCAL text (e.g. a password for the auto-spawned SecurityAgent dialog pane) could never reach a remote field. FIX, three reachable affordances: (1) a footer `Menu` on the live pane — "Paste as Keystrokes" (types the CURRENT local clipboard) + a "Clipboard Ring" submenu of recent clips with classifier-aware previews (SECRETS MASKED to length only, never echoed). A footer menu, NOT a surface context menu, which would steal the secondary-click the pane forwards to the host window. (2) the ⌥⌘V chord — a proper registry row `view.pasteAsKeystrokes` (⌥⌘V is FREE — `v` is in no other chord; plain ⌘V/⌘⇧V belong to the terminal's own paste responder, never the registry) → `WorkspaceStore.pasteAsKeystrokesInActivePane()` → the ACTIVE pane's `PaneSessionHandle.pasteAsKeystrokes(_:)` (default no-op; `LivePaneSession` forwards to `RemoteWindowModel`) → the video view's published key sink; a graceful no-op for a terminal / empty / read-only / not-streaming pane and an empty clipboard. (3) the existing "typed N, skipped M unmapped" result banner is surfaced as a tap-to-dismiss footer pill. The CURRENT clipboard is read live via the new app-injected `WorkspaceStore.clipboardTextProvider` (`NSPasteboard` on macOS), so it works even when clipboard-history recording is off; `currentLocalClipboard()` falls back to the ring head when no provider is wired. → `ClipboardPasteMenu.swift` (new, pure), `WorkspaceStore.swift`, `WorkspaceStore+RemoteWindow.swift`, `PaneSessionHandle.swift`, `LivePaneSession.swift`, `WorkspaceBindingRegistry.swift`, `WorkspaceBindingRouting.swift`, `GuiLeafView.swift`, `SlopDeskClientApp.swift`; pinned by `ClipboardPasteMenuTests` (masking / ring listing / enablement) + `TreeCommandRoutingTests` (⌥⌘V row + active-pane-only clipboard routing + empty-clipboard no-op + provider-then-ring precedence) + `FakePaneSession` (records the payload). The footer `Menu` / banner render is app-target/manual-verify.
- ✅ **Link-health indicator model (C7 improvement 1, pure)** — `LinkHealth` maps one `Sample` of the video session's already-tracked RTT / windowed loss% / FEC-recovered counters onto a display `Grade` (good/degraded/bad → green/amber/red dot), a compact RTT label ("23ms" / "1.5s" / "—"), and a tooltip ("RTT 23ms · loss 1.4% · recovered 12"). Thresholds cross on the WORSE of RTT/loss; NaN/negative reads sanitize to good. → `LinkHealth.swift` (new); pinned by `LinkHealthTests`. The footer dot render + the session→model stat push (mirroring `noteStreamFps`) is the HW-verify wiring step.
- ✅ **Frozen-stream detector policy (C7 improvement 2, pure)** — `StreamStallPolicy` decides `.live` / `.stalled` / `.notConnected` / `.unknown` from `(now, lastFrameAt, lastHeartbeatAt, connected, idleSkipActive)`, built around the IDLE-SKIP trap: idle-skip suppresses frames by design, so during idle-skip liveness is judged by the HEARTBEAT alone (a stale last-frame is expected) — a healthy idle window is NOT stalled; a genuinely silent heartbeat past the threshold IS. Stalled only while connected (a hard disconnect owns its own path). → `StreamStallPolicy.swift` (new); pinned by `StreamStallPolicyTests` (the idle-skip-with-fresh-heartbeat regression + boundary + unknown-on-fresh-connect). The scrim overlay + reconnect trigger driven off the session's frame/heartbeat clocks is the HW-verify wiring step.
- ✅ **Oversized-viewport edge-hint model (C7 improvement 3, pure)** — `ViewportEdgeHints.compute(contentSize:viewportSize:offset:)` maps the existing viewport geometry (content size, visible size, pan offset) onto which of the four edges have OFF-SCREEN content, so the edge-hover pan (otherwise invisible) can draw slim gradient hints like scroll shadows. Clamps a stray/overshooting offset to the reachable range so it can't fabricate a phantom edge; content that fits hints nothing. → `ViewportEdgeHints.swift` (new); pinned by `ViewportEdgeHintsTests` (origin / max / middle / wide-only / over-fit / clamp). The gradient overlay + one-time first-hover cursor cue driven off the live viewport offset is the HW-verify wiring step.

## Terminal surface UX: reconnect-outcome toast + `--new-window` degrades to a tab + collapsed-sidebar connection indicator (fix batch, 2026-07-03)

> Three terminal-surface signal gaps, all surfaced from state the client already tracks. No wire change (golden corpus untouched); the two view renders (toast push, the collapsed-sidebar chip) ride existing seams.

- ✅ **Reconnect surfaces WHICH kind it was (C8 improvement 1)** — `SessionResumeOutcome` (the seq-derived warm-vs-fresh verdict added in the 65-bug batch) was computed but never shown, so an unexpected drop that came back on a FRESH shell silently discarded the user's scrollback/history with no cue. `TerminalViewModel` now fires a new one-shot `onResumeOutcomeResolved` when the verdict resolves — gated on a NEW `resumeOutcomeNotifiable` flag armed by `markReconnecting()` and CLEARED by `reset()`, so the toast fires ONLY after an UNEXPECTED drop→reconnect (never on first launch or a deliberate ⇧⌘R). It forwards `ConnectionViewModel.onResumeOutcomeResolved` → `WorkspaceStore.onSessionResumeOutcome(paneID, outcome)` → the app pushes `Toast.sessionResume(...)`: `.resumedSession` → a `.success` "Reattached / Session preserved."; `.freshShell` → an `.attention` "Reconnected / Fresh shell — previous session ended." (`.undetermined` ⇒ no toast). → `TerminalViewModel.swift`, `ConnectionViewModel.swift`, `WorkspaceStore.swift`, `Toast.swift`, `SlopDeskClientApp.swift`; pinned by `ToastSessionResumeTests` (outcome→banner mapping) + `TerminalViewModelWarmReconnectTests` (fires resumed/fresh once after a reconnect; SILENT on a fresh connect). The toast render is the existing `ToastStackView` path.
- ✅ **`--new-window` degrades to a new TAB in the current session (C8 improvement 2, re-scope)** — the `WorkspaceControlBackend.open` `.newWindow` arm minted a NEW SESSION and swapped the whole UI to it; with the session switcher pruned (§487) there was no way back. It now calls `store.newTab(kind:)` — no orphan session is ever user-created. The control-plane verb name `--new-window` stays for CLI compat (`ClientControlProtocol.Placement.newWindow` and the `slopdesk edit/view --new-window` CLI are unchanged); only its client placement target changed. The now-dead `shimSessionName` helper is removed. The session DOMAIN (templates / persistence / agent-control `newSession`) is untouched. → `WorkspaceControlBackend.swift`; pinned by `WorkspaceControlBackendTreeTests.testNewWindowPlacementOpensTabInCurrentSession` (session count stays 1, +1 tab, shim lands on the new leaf).
- ✅ **Durable connection indicator when the tabs panel is collapsed (C8 improvement 3)** — with the sidebar hidden (⌘⇧L) a dropped/reconnecting pane had no per-pane visible surface. `WorkspaceConnectionAlert.resolve(from:)` (new, pure) folds every live pane's `ConnectionStatus` into `nil`-when-all-healthy vs `{ count, worst severity, worstPane }`; only `.reconnecting` / `.failed` / `.unreachable` are alarms (`.connecting` / deliberate `.disconnected` / no-connection are not), worst by the rail's `unreachable > failed > reconnecting` order, worst-pane tie-break = first-at-worst in tree DFS order. `WorkspaceStore.connectionAlert()` gathers the live statuses (observation-registering, so it re-renders on drop/recover); `OverlayHostView` shows a compact amber/red `ConnectionAlertChip` at the bottom ONLY while `chrome.sidebarCollapsed`, whose click `focusPaneTree`s the worst pane. → `WorkspaceConnectionAlert.swift` (new), `WorkspaceStore.swift`, `OverlayHostView.swift`, `WorkspaceRootView.swift`; pinned by `WorkspaceConnectionAlertTests` (hidden-when-healthy / count / worst-severity / stable tie-break / classification). The chip render is app-target/manual-verify.

## Native SwiftUI chrome migration (2026-07-03) — RE-SCOPES the flat otty/Slate design

> The product grew a second content region (remote windows / dock / GUI column) and the flat single-backdrop design stopped carrying the added structure. Decision: **chrome goes native macOS (Liquid Glass era), the content canvases stay custom/opaque** — the exact split Apple ships in Terminal.app 26 (glass chrome, opaque text canvas). This deliberately overturns the 2026-06-24/25 "flat pane / one backdrop / no system vibrancy" doctrine for CHROME; the flat doctrine survives only INSIDE the terminal/video canvases.

- ✅ **Shell = pure SwiftUI `NavigationSplitView`** (sidebar | detail) on macOS — replaces the AppKit `NSSplitViewController` + `NSHostingController`-per-column shell (and with it the isa-swizzled `FlatDividerSplitView`, the mouse-truth divider tracker, `safeAreaRegions=[]`/`sizingOptions=[]` hacks, and the `NSWindow.appearance` re-pin). One SwiftUI hierarchy ⇒ `@Environment`/`.tint`/`.preferredColorScheme` now reach every column — the D3 boundary problem dissolves instead of being worked around. iOS already runs this shell; the platforms converge.
- ✅ **Native titlebar + unified glass toolbar** — `.hiddenTitleBar` is dropped; `SlateTitlebar` (hover-reveal custom chrome) is deleted. Sidebar toggle = the system's; title menu, connection cluster, windows-panel toggle = native `ToolbarItem`s.
- ✅ **The GUI column stays a keep-mounted detail region, NOT `.inspector`** — `.inspector(isPresented:)` unmounts its content when dismissed, which tears down live video surfaces (violates the SplitContainer identity-preservation invariant). The right column collapses by width/opacity with the panes kept mounted — same semantics `NSSplitViewItem.isCollapsed` had.
- ✅ **Canvas keeps Slate; chrome sheds it.** The Monokai Pro theme engine shrinks to the terminal-cell/video canvas; window chrome follows the SYSTEM appearance + accent (semantic colors, native text styles, materials). Custom glass (`glassEffect`) is used sparingly, never OVER a live `CAMetalLayer`, and always gated on Reduce Transparency.
- ✅ **The ds-leaks ratchet INVERTS**: raw font/radius literals are no longer banned (native idioms are the target); instead `Slate.` usage in `SlopDeskClientUI` is a monotonically-decreasing count (baseline file, fail on increase) so the migration only moves forward.

## Card-canvas: panes float as rounded cards (2026-07-04) — RE-SCOPES the last flat-canvas remnant

> The user judged the native-chrome shell clearly native but still not attractive or modern enough. The flat flush canvas (terminal pixels edge-to-edge, hairline dividers, zero depth) read as plain next to the glass chrome. Decision: the CANVAS presentation goes **card-based** — every pane is a rounded floating card on a darker theme margin — the Xcode 26 / Freeform "page on under-page" idiom, in the canvas theme's own hue. The theme engine still owns every canvas colour (no system grays over the canvas); only the *presentation* changes.

- ✅ **Pane = rounded card**: `PaneContainer` clips its content (scrim + drop overlays included, so the hosted libghostty/video `CAMetalLayer` is masked too) to a 10pt continuous rounded rect on `Surface.card`, with a theme `Line.cardBorder` hairline and a soft `Effect.panelShadow`. The terminal surface's pre-existing 8pt inner inset keeps corner glyphs clear of the rounding.
- ✅ **Margin backdrop = theme `sidebar` tone** (`Surface.margin`) behind ContentColumn/GuiColumn/SplitContainer — same hue family as the canvas (a neutral system gray would clash with warm/tinted Monokai filters), darker so the cards read as lifted.
- ✅ **Split seam = the gutter**: each card insets `paneGap/2` (4pt) inside its solver rect and the columns pad by the same half-gap, so inter-card gap == outer margin == 8pt. `PaneDivider` draws NOTHING at rest (the gap is the seam; hit band + resize cursor unchanged) and an accent line only while dragging. Solver geometry, move handles, and drop zones are untouched — the inset is purely visual.
- ✅ **Focus = accent border on the focused card of a SPLIT** (2pt, 75% accent) — replaces the flat-era top-left corner triangle, which a rounded corner would have clipped. A solo/zoomed pane draws no ring (nothing to disambiguate).
- ✅ **Sidebar icons tint accent** (`NavigatorRow`) — the Mail/Finder system-sidebar idiom.
- Dead flat-era tokens removed with their last consumers: `NativePaneColor.separator`, `Slate.Line.divider` (the `SlateTheme.divider` DATA field stays — theme structs keep every role).

## Region rhythm: one margin surface, centred status, dock floats, sidebar footer (2026-07-04) — layout restructure over the card-canvas

> The user judged the card-canvas pass better, but felt the layout could be restructured to look nicer. The cards were right but the REGIONS around them still carried flat-era seams: a system-gray strip + hairline slicing the two themed columns apart, a hard rule under the window dock, status crowded into the toolbar's trailing corner, and no mouse-visible New-Tab mint anywhere on macOS. Decision: the detail area is ONE continuous margin surface with a deliberate gutter rhythm, and the chrome recomposes to the native seats.

- ✅ **One continuous margin surface** — the macOS detail `HStack` itself backs `Surface.margin`, so the GUI-panel divider band no longer exposes the system window background between the two themed columns. Gutter rhythm: cards within a region sit `paneGap` (8pt) apart; the two REGIONS sit a double gap (16pt = 4+8+4) apart across the divider band — hierarchy by spacing, not by lines.
- ✅ **`GuiPanelDivider` goes invisible-at-rest** (the `PaneDivider` language): no hairline; the gutter IS the seam; a 2pt accent line appears only while dragging. Band width 9→`paneGap`; hit band + column-resize pointer + commit-on-release discipline unchanged.
- ✅ **Connection cluster moves to the titlebar CENTRE** (`.principal` — the Xcode activity-pill seat) with a resting bezel fill; trailing keeps the actions (pane menu, windows-panel toggle). Ambient state reads from the middle; actions live at the edge.
- ✅ **`.navigationSubtitle` = the focused pane's cwd**, home-abbreviated via the palette's `CwdDisplay` (the document-proxy idiom); empty until known.
- ✅ **The window dock floats on the margin** — the hard `Divider()` under it is gone; the strip gets breathing room instead (the space to the video card below is the seam). Tiles grow to 32pt icons.
- ✅ **Sidebar footer New-Tab affordance** (`safeAreaInset(edge: .bottom)`, the Things/Reminders idiom) — before this, macOS had NO mouse-visible tab mint (⌘T / palette / menu only). Mints a terminal tab; remote windows keep minting from the dock's `+`.

## Sidebar-navigator windows + pure-content GUI column: the dock is removed (2026-07-04)

> The user judged the region-rhythm pass's layout still not attractive or elegant, and the dock illogical. The dock strip was the layout's odd organ: it fused two different things into one persistent band of icon tiles — the OPEN remote-window tabs (navigation) and the host's not-yet-open windows (a launcher) — with middle-truncated captions, above the video it stole height from. Decision: **navigation goes to the sidebar, launching stays in the picker, the GUI column becomes pure content.**

- ✅ **The window dock is DELETED** (`WindowDockStrip`/`WindowDockTile`/`WindowDockModel` + the GuiColumn discovery poll). The GUI column renders only the `SplitContainer(side: .gui)` pane area — the video card top-aligns with the terminal card across the region seam, uniform half-gap margins all round.
- ✅ **Sidebar gains a "Windows" section** (macOS): one native `List` row per OPEN remote-window tab — the host app's REAL icon (resolved locally from the endpoint's `bundleID` via the surviving `AppIconResolver`; SF-symbol fallback), window title, host-app subtitle. Selecting a row activates its GUI tab (the right column's displayed tab) — the Mail/Xcode source-list idiom. The flat terminal list gets a "Terminals" header whenever the Windows section is present, so the two groups read as named peers. Windows rows are not drag-reorderable and carry a slim context menu (rename/close).
- ✅ **`VideoEndpoint` carries `bundleID`**, stamped at mint time from the picker's discovery summary (`newRemoteWindowTab(windowID:title:appName:bundleID:)`) — the sidebar needs NO discovery poll (the dock's 4s poll dies with it). Decoded tolerantly (missing key → ""), so pre-existing trees still load.
- ✅ **Launching = the Remote-Window picker only**, minted from the sidebar footer's window-`+` (`macwindow.badge.plus`, right side of the New-Tab footer), the GUI column's empty state, and the palette. A persistent launcher strip of every host window was chrome noise; browsing is an on-demand act.

## Card-on-glass canvas: pane cards on the NATIVE window glass (2026-07-04 v3) — RE-SCOPES the flat hairline canvas

> After HW-testing the flat hairline canvas, the user asked for the terminal and the remote window each on its own card, with the app background fully native (liquid glass) rather than the terminal background colour. The v1 card-canvas was rejected for its BACKDROP, not its cards: the theme margin (`0x221F22`) sat within a few RGB points of the card fill (`0x2D2A2E`) — no depth read, full space tax. Decision: bring the cards back, but float them on the window's OWN glass.

- ✅ **Backdrop = native under-window glass, never a theme colour.** `WindowGlassBackdrop` (macOS: a behind-window `NSVisualEffectView` `.underWindowBackground` — the same material the system sidebar/titlebar sit on; iOS: the system background) renders behind the whole detail (both columns + the region seam). The window reads as ONE continuous liquid-glass surface; the theme lives only on the cards (and the cells inside them). `NativePaneColor.window` and the column/detail `Surface.card` fills are deleted.
- ✅ **Every pane is a card**: terminal and remote-window leaves clip to a 10pt continuous rounded rect on the theme card fill, with a theme `cardBorder` hairline and a soft `panelShadow`. Siblings sit `paneGap` (8pt) apart — the leaf insets by half the gap inside its solver rect (geometry untouched), and the columns pad by the same half, so window-edge margin == inter-card gap (one 8pt rhythm).
- ✅ **Seams are the glass gaps**: `PaneDivider` and `GuiPanelDivider` draw NOTHING at rest (the gutter is the seam) and show the accent line only while dragging. `Slate.Line.divider` is deleted; `Line.cardBorder` + `Effect.panelShadow` + `Metric.paneGap`/`paneCornerRadius` return.
- ✅ **Focus treatment unchanged** (the unfocused-sibling theme veil, no animation) — the restructure's ambient-status / native-toolbar / content-driven-height rules all stand.

## Minimalist reset: the design-craft decoration layer is REMOVED (2026-07-04 v5) — RE-SCOPES the visible-design + design-craft passes

> The user judged the decorated canvas cluttered with redundant detail, inelegant, full of out-of-place elements, and AI-slop-looking, and asked to return to the minimalist otty interface. Decision: the at-rest frame carries NO ornament — the card-on-glass v3 canvas (2026-07-04) is the resting look, full stop. Everything the visible-design (v4) and design-craft passes layered on top is deleted; features that only *appear on activity* and carry information survive.

- ✅ **Deleted, decoration**: depth-ladder margin tint + static grain (`CanvasBackdrop`/`GrainTexture`), terminal film-texture shader (grain+vignette on the cells), cursor motion-trail shader, ambient light engine (NV12 sampling → `AmbientPalette` → canvas underlay, incl. the busy-only glow), session masthead display type, empty-state aurora, cinematic tab-switch springs/parking, glass-panel frost (`GlassPanel` — overlays return to plain native materials), badge pop/symbol-morph, toast spring, breathing status dot, accent focus-border hue (plain `cardBorder` again). Earlier the same day the restraint pass had already deleted the session colour identity + corner bugs; this pass finishes the job.
- ✅ **Kept, functional**: Control Room (⌘⇧M live overview — chrome now on plain materials), long-command elapsed/outcome chip, OSC 9;4 sidebar percent ring (no pop/opacity transitions), video letterbox/first-frame fade/opt-in stats HUD.
- The bar (unchanged from the restraint pass, now fully enforced): an at-rest visual change must be tonal/structural/typographic and must earn its place; chromatic spread, texture, and permanent per-item ornament read as AI slop. ds-leaks ratchet 60 → 52.

## Full reset to the otty shell: pre-split, pre-native-chrome (2026-07-04 v6) — RE-SCOPES the split workspace, the native chrome migration, and every canvas pass after it

> After the v5 minimalist reset still read as the old UI, the user asked to return to the real otty chrome as a development base, and to restore panes being able to be either a terminal or a window. Decision: the tree snaps back to `567fa61` — the last commit where macOS chrome is the otty shell (`SlopDeskSplitViewController` + `SlateTitlebar`/`SlateTabRow`, iOS keeps its stock `NavigationSplitView`) and a pane can still be EITHER a terminal or a remote window inside one workspace tree (the in-pane chooser). This state is the new development base.

- ✅ **Reverted wholesale** (everything after `567fa61`): the terminal ⟂ remote-window split-workspace columns + `TabSide` + GUI dock (incl. the `WindowSummary.bundleID` wire growth on video type 8 — the wire returns to the base shape; host+client redeploy together per the no-backcompat rule), the entire native SwiftUI chrome migration (NavigationSplitView shell, native List sidebar, materials pass, native FirstLaunch), and every canvas/design pass stacked on it (card-canvas, region rhythm, card-on-glass v3, visible-design v4, design-craft, and the v5 minimalist strip — all moot: their substrate is gone).
- ✅ **Re-applied on top, kept through the reset** (they fix real bugs / add a real tool, independent of chrome): video-host input-drop tracing (`9b3dc2c`), self-healing reconnect after a videohostd restart incl. `UnboundLaneByePolicy` (`45d0401`), the stall scrim — host 1s heartbeat + `StreamStallPolicy` + sticky Reconnecting… overlay (`9fa3776`), and `slopdesk-perfbench` + its encode-wall findings (`00a1972`, `54cac2a`).
- The v5 bar (at-rest = zero ornament) still stands — it now applies to the otty shell.

## Scrollback survives the host: per-session disk journal + fresh-spawn restore (2026-07-10)

> The user reported that reconnecting loses history, and asked to persist all of it server-side like tmux/zellij. The RAM half already existed (ReplayBuffer seq replay, DetachedSessionStore, 4 MiB scrollback ring, ScrollbackDistiller). History was actually lost only on the paths that end in a FRESH spawn (`spawnFreshShell`, PATH B/C): hostd restart / reboot (everything was in-memory), detach-TTL eviction, and shell death. Decision: a host-side per-session **disk journal** + **restore-on-fresh-spawn**. No wire change, no client change, and explicitly NOT a sessiond — a live process cannot survive the daemon; the TRANSCRIPT does, and a fresh shell spawns beneath it (the tmux-resurrect model, not the tmux-server model).

- ✅ **`ScrollbackJournalStore`** (`SlopDeskHost`): one raw-bytes file per client-owned session UUID under `<AppSupport>/SlopDesk/scrollback/`. Appends ride the PTY read-loop chunk path (`ingestPTYChunk`) on a per-journal serial queue; capped at the scrollback-ring size (`SLOPDESK_SCROLLBACK_BYTES`, default 4 MiB) by tail-keeping compaction (cut advanced past the next `\n`). Detached-era output keeps journaling (the read loop survives `detach()`).
- ✅ **Restore gate = fresh spawn + returning ID + COLD client.** `spawnFreshShell` loads the journal only when `open.sessionID` is a real (non-sentinel) resume ID AND `open.lastReceivedSeq == 0` (a warm client still holds its rendered surface — replaying would double-print). The restored transcript is distilled (`ScrollbackDistiller`) + suffixed with a mode-sanitize reset (exit alt-screen/mouse/bracketed-paste, SGR reset, cursor show), then enqueued as the FIRST output frames — through the normal drain, so it lands in the new ReplayBuffer with ordinary seqs. It is NOT re-journaled (the journal hook sits on the PTY chunk path, which the preamble never crosses) — no doubling across restarts.
- ✅ **Deletion = deliberate end only.** `removeMuxSession` (peer `channelClose` / attached child exit) deletes the journal; link-drop detach, TTL eviction, detached-exit, and daemon `stop()` keep it. Orphans are bounded by an init-time sweep (age > 14 days, keep newest 256).
- ✅ **Gating**: store is built in `slopdesk-hostd` main via `ScrollbackJournalStore.makeFromEnvironment()` (`SLOPDESK_SCROLLBACK_PERSIST != "0"` AND new `SLOPDESK_SCROLLBACK_DISK != "0"`), AND-ed with `detachEnabled` inside `HostServer` (without detach the client never re-presents an ID, and link-drop would route to the deleting path). `HostServer(scrollbackJournals:)` defaults `nil`, so unit tests never touch the real Application Support dir.
- Drive-by: `spawnMuxChannel`'s reattach guard compared `open.sessionID != UUID()` — a fresh RANDOM uuid, i.e. always-true — where the comment meant the zero sentinel; now compares `WireMessage.newSessionID`.
- ✅ **Detach TTL default → NEVER (follow-up, same day).** tmux/zellij never reap a detached session on a timer — and a detached SlopDesk pane is often a deliberately-left-running agent. `SLOPDESK_DETACH_TTL_SECS` unset/`0` now means keep indefinitely (`HostServer.detachTTL: Duration?`, nil = no eviction task armed); a positive value opts back into timed eviction. The `DetachedSessionStore` 64-session cap (oldest-evicted) + the 4 MiB offline PTY-drain gate remain the resource bounds.
- ✅ **Detach cap → UNBOUNDED by default + fd headroom (follow-up, same day; supersedes the interim 64→256 bump).** Verified against both sources: tmux (`session_create` — no bound check) and zellij (per-session server, no MAX constant) have NO session cap and NEVER silently kill a live detached session; their real bounds are per-pane scrollback limits (2000 / 10 000 lines), which SlopDesk already exceeds in strictness (4 MiB ring + 4 MiB journal + 64 KiB FIFO + offline drain gate per session). Count-based eviction of a LIVE session is therefore wrong semantics — `SLOPDESK_DETACH_MAX_SESSIONS` unset/`0` = no cap (default); a positive value opts into oldest-evicted capping. hostd raises `RLIMIT_NOFILE` soft toward 8192 at start (PTY master + journal fd per pane, far past macOS's default 256 soft limit) — fd exhaustion then fails a NEW spawn loudly instead of killing an OLD session silently.
- ✅ **Per-session caps loosened for ≥32 GB hosts (follow-up, same day).** The user noted the caps were too tight and asked to loosen them, since all the machines have 32 GB. Scrollback ring + disk journal 4 → **64 MiB**/session (`SLOPDESK_SCROLLBACK_BYTES` still overrides both); ReplayBuffer offline gate 4 → **64 MiB**, retained ceiling 64 → **256 MiB** (never-drop invariant unchanged — the caps only move the pause trigger). And the cap that actually bit the "leave the agent working, close the laptop" workflow: the 64 KiB PTY queue gate is a LATENCY bound that, while detached, stalled the still-running agent at 64 KiB + one kernel buffer — `detach()` now re-sizes it to a **64 MiB "output while away" budget** (`SLOPDESK_MUX_DETACHED_QUEUE`; `BoundedQueuePolicy.setCapacity` preserves accounting, gate re-applies pause atomically) and `rebindRelay` restores the attached sizing (backlog ships to the returning client, then normal latency bounds resume). tmux-parity note: tmux never stalls the process — it trims history; SlopDesk keeps never-drop for the live stream and bounds by budget instead, with the disk journal catching the long tail.
- ✅ **Replay hygiene: `TerminalQueryStripper` (follow-up, same day).** Replayed history contained the prior life's terminal QUERIES (DA1 `CSI c`, XTVERSION `CSI >q`, DECRQM `CSI ?2026$p`, OSC `11;?`) — the client terminal answered them AGAIN and the responses rode back as PTY input, spilling onto the command line (`^[]11;rgb:…^G^[[?62;22;52c…` after `sleep 300` + reopen). A pure host-side stripper now removes queries, echoed responses, and stale color/clipboard state (OSC 10/11/12/4/52…, set forms included) from the REPLAY transforms only — `ScrollbackReplayTransform.make` composes distill→strip for both the ring's cold-reattach pass and the journal restore (`SLOPDESK_SCROLLBACK_STRIP_QUERIES`, default-ON). The un-acked live tail stays byte-exact: a query there was never delivered, so its issuer may legitimately still await the answer. Stored bytes stay raw — the stripper retroactively cleans already-poisoned journals.

## Terminal-path stability audit: 15 confirmed defects fixed (2026-07-10)

> The user asked for a careful re-audit of existing features to increase stability, with terminal persistence handled especially carefully. A 24-agent adversarially-verified audit (8 subsystem finders → 1 refuter per finding, 15/16 confirmed) over the terminal path. Every fix is test-first (each new test was proven to FAIL on the pre-fix code). No wire change; golden untouched.

- ✅ **Session identity is single-owner, enforced in ONE critical section.** The reattach race cluster (the audit's only CRITICAL): `DetachedSessionStore.lookup` returned the session WITHOUT removing it, and `detach → Task { store.insert }` was fire-and-forget — two concurrent reconnects (or a reconnect racing the armed TTL task / a fast reconnect racing the un-scheduled insert) could alias ONE live session under two keys or spawn a SECOND shell on the same sessionID; the loser's later close then **killed the winner's live PTY and deleted its journal**. Now: the store is a lock-guarded class (`claim()` = remove + TTL-cancel atomically; `insert` completes before `detachMuxSession` returns), and `spawnMuxChannel` decides stopping/duplicate-key/attached-elsewhere/claim in one `lock` hold — a sessionID lives in exactly one of {muxSessions, store}, a second open for a LIVE sessionID is refused (`accepted: false`), and `rebindRelay` reports failure instead of silently no-opping.
- ✅ **A host refusal now actually closes the client channel.** `ChannelTable.reject` only transitioned from `.idle`, but production marks the channel `.open` optimistically in `openChannel()` — a real refusal (stopping, reattach race) left the pane registered, open, and silent forever. `reject` closes from `.idle` AND `.open`; the sub-channels finish, so the UI/reconnect layers observe the failure.
- ✅ **Reconnect never discards claimed-but-unconsumed output.** The client's `resumeFromSeq == 0` reset wiped `outputInbox` — bytes already claimed to the host via `lastReceivedSeq` (advanced at wire-ARRIVAL, not consumption) that a reattaching host will never resend: a silent permanent scrollback gap at every reconnect that raced an undrained burst (deterministic on iOS pause→resume). Carried entries now survive the reset with their wire-credit zeroed (no phantom windowAdjust on the new channel — the wipe's original motivation).
- ✅ **One PTY exit waiter, ever.** `rebindRelay` cancelled+recreated the exit task per reattach, but `PTYProcess.waitForExit` parks a plain continuation with no cancellation plumbing — every cycle left one more waiter and the pane sent a duplicate `.exit` frame per reconnect. The single `startRelay` exit task (which reads `onExit` at fire time) is now the only waiter.
- ✅ **Replay frames respect the credit progress invariant.** `ReplayBuffer.rechunk`'s hardcoded `max(32 KiB, …)` floor emitted 32768-byte payloads = 32781 wire bytes > window/2 — the documented "13-byte dead zone" wedge, reintroduced on the cold-reattach path. Clamped to `MuxFlowControl.maxOutputFramePayloadBytes` like the live drain.
- ✅ **Stripper closes the response gaps**: DECRQSS/XTGETTCAP echoed responses (`{0|1}$r…`/`{0|1}+r…`, ghostty's reply formats) and OSC 21 (kitty color protocol) join the strip set.
- ✅ **Mux hardening, client side + id reuse**: the client drops unsolicited `channelOpen` (a buggy/compromised host could grow its router table without bound — the client-side mirror of R11); the host refuses a `channelOpen` for a terminally-closed id (same-id open→close churn used to fork a fresh PTY per cycle, unbounded).
- ✅ **Journal robustness**: `sweep()` exempts files with LIVE writers (unlink-under-writer = silent total transcript loss via writes to an unlinked inode); `compact()` clears the FileHandle even when `close()` throws (a poisoned handle silently dropped every future append); a failed `seekToEnd()` on reopen is an open failure (the fd sits at offset 0 — writing would overwrite the journal head with undetected corruption).

## Broad stability + performance audit: 23 confirmed findings fixed (2026-07-10)

> The user asked to continue a comprehensive audit and, in parallel, audit performance for anything that could be optimized. Second audit round, same adversarial shape (14 finders — 8 stability over the subsystems the terminal-path round did NOT cover, 6 performance over the hot paths — → 1 refuter per finding; 27 raw → 23 confirmed / 4 refuted). All fixes test-first; perf refactors additionally pinned byte-identical behavior BEFORE the change (pin tests green pre- and post-refactor; the stripper/distiller pass also differential-fuzzed HEAD vs. working tree, 4000 rounds). No wire change; golden-check byte-identical.

**Stability:**
- ✅ **A bogus ack can no longer wedge a session forever (CRITICAL).** `ReplayBuffer.ack(upTo:)` accepted any wire seq and set `ackedSeq` past `highestSeq` — after which every legitimate ack was `<=` and silently dropped, the buffer only grew, and at the 256 MiB cap `shouldPauseDrain` froze the PTY permanently (only a full reconnect could recover). The seq is now clamped to `highestSeq` before the monotonic guard.
- ✅ **The agent-control `spawn` verb can no longer crash hostd.** `UInt16(params["rows"])` on the AF_UNIX NDJSON ctl socket trapped the whole daemon on any out-of-range value; it now validates `1...65535` exactly like its sibling `resize` and returns the standard error response.
- ✅ **SCStream death is propagated, not papered over.** `didStopWithError` was log-only: the IDR timer kept re-encoding the stale `cachedPixelBuffer`, the 1s heartbeat kept the client's stall scrim disarmed, and the pane froze silently forever (window closed, display unplugged, TCC revoked). The capturer now quiesces (timer cancelled, cache cleared, once-only latch vs. deliberate `stop()`) and fires `onCaptureFailed`, which drives the existing last-rung teardown (`bye` ×2 + stop) so the client's reconnect path engages honestly.
- ✅ **FrameReassembler pins `fragCount` like it already pinned `fecTier`.** A crafted/corrupt duplicate fragment carrying a smaller count silently shrank the data/parity boundary — the frame completed MISSING real buffered bytes and the loss signal never fired. A disagreeing count is now validate-then-dropped as `.stale`.
- ✅ **NACK grace and DecodeSequencer patience are reconciled.** With `SLOPDESK_NACK=1`, the sequencer's stock valves (maxHeld 4 / maxGap 6) tripped ~3 frames BEFORE the 8-frame retransmit grace could land, flushing out-of-order over the still-missing frame with the gate `.open` — reintroducing the -12909 cascade the sequencer exists to prevent. Patience is now floored at `grace + 2` when NACK is on; the default path is pinned unchanged.
- ✅ **A closed video pane stays closed.** `RemoteWindowModel.revalidateBinding()` acted on its discovery verdict unconditionally after the await — `close()` mid-flight was followed by a silent `pick(); open()` revival. A `closeGeneration` snapshot + `Task.isCancelled` + same-descriptor check now gates the verdict.
- ✅ **Typing in Settings no longer reconfigures every terminal per keystroke.** Free-text font fields bound straight into `PreferencesStore.terminal`'s `didSet` → JSON persist + libghostty config reload + PTY resize across every open pane, per character. Those fields are now draft-backed (commit on ~500ms idle / submit / blur / disappear); discrete controls stay write-through. The Connect sheet got the sibling fix: its completion is generation-guarded and the task cancellable, so a stale slow connect can't dismiss a reopened sheet mid-edit.
- ✅ **Inspector bounded + honest.** The per-subscriber live AsyncStream was `.unbounded` (a stalled peer buffered every event forever; only `history` was capped) — now `.bufferingNewest(snapshotCount + 1024)`, sized so a full replay snapshot always survives; a gap forces a `fromSeq:` resubscribe, the already-precedented recovery. The unused `InspectorSource.stream(_:)` pump now terminates on send failure instead of draining a dead peer forever.

**Performance** (the theme: three independent finders converged on `Array.removeFirst()`-as-queue on hot paths — all now the same head-cursor + amortized-bulk-compact idiom `FrameDecoder` already documented):
- ✅ **Reattach backlog drain O(n²) → O(n).** `MuxChannelSession.outFIFO` popped front-first per entry and head-reinserted split remainders; a 64 MiB detached backlog of small reads ≈ 330k entries ≈ 10¹¹ element shifts on reattach. Measured: 250k-entry drain 15.4s → 0.17s (~90×). Same fix client-side (`TerminalViewModel` replay ring, MainActor, ahead of `feedBatch`: 150k-chunk shape 3.4s → 0.16s) and in `ReplayBuffer.evictScrollbackToFit` (bulk `removeFirst(dropCount)` under `replayLock`, which the live send path shares).
- ✅ **One less full-payload copy per PTY chunk** (blocks tracker no longer does `Array(chunk)` — the segmenter ingests `Data` directly) and **lazy CSI param materialization** in the stripper (no String alloc for SGR, index-range slices instead of per-byte array builds) + the distiller iterates `[UInt8]` not `Data` — the cold-reattach/journal-restore transforms now scan multi-MiB blobs without per-sequence allocations.
- ✅ **Video datagrams: 1 memcpy instead of 2-3, each direction.** Send built `[tag]+payload` then re-appended it into the header buffer (host + client) — now one `encodeMedia` writing header+tag+payload once, byte-pinned against manual wire construction. Receive stopped double-copying the tail slice (`VideoByteReader.remaining()` returns the slice; tag-strip passes a slice through); the one durable copy (fragment payload) is kept, and an audit of every `remaining()` caller confirmed nothing retains a slice (no parent-buffer pinning).
- ✅ **Reassembler completeness is O(1) per fragment, not O(fragments).** With fragCount+fecTier both pinned, the FEC geometry resolves once per frame and per-group missing/surviving tallies update incrementally — a ~2100-fragment 4K IDR no longer pays ~3M dictionary probes serialized ahead of decode. Duplicate fragments provably don't double-count (the trap the pin tests nail down).
- ✅ **Journal writes coalesce.** One `write(2)` per PTY chunk → a 32 KiB / 25ms-idle buffer on the journal's serial queue; every reader path (restore, compact, synchronize, delete) flushes first, buffered bytes count toward the cap, and a deliberate delete discards the buffer (no resurrection by a late idle timer).
- ✅ **The sidebar no longer rebuilds O(panes) on every status tick.** `RailRowsBuilder.rows(for:)` ran in the NavigatorColumn body reading ~8 whole-dictionary observables — any pane's agent/git/progress tick (or the 1 Hz video telemetry) re-walked every row + disambiguation + sectioning. Now: rows are memoized on a structural fingerprint (tabs/panes/specs/projectKeys), volatile chrome moved into per-row leaf views (`liveChrome`), telemetry into a footer leaf. Residual: a tick still re-evaluates cheap leaf bodies (dictionary-granularity Observation) and agent-status EDGES still restructure (they legitimately reorder `.updated` sort); the O(panes) model rebuild is gone from the tick path.

## Sidebar grouping: host-computed By-Project key, group/sort options REMOVED (2026-07-10)

> The user asked to remove the settings group and sort-by controls, always group by project with no sorting, and to compute these on the server so a reconnecting client never recomputes them (instant) — and a standing directive that the SERVER is the single source of truth so any number of client reconnects converges on the same state.

- ✅ **WIRE EXTENSION (golden corpus +1 vector): new CONTROL type 34 `projectKey(path)` (host → client).** The host is now the single source of truth for the By-Project sidebar key: it derives the pane's cwd (OSC-7 sniff when the shell emits it, else a `proc_pidinfo` probe at the OSC-133 B/D **prompt edge** — exactly when a `cd` becomes observable; Starship/hookless shells covered), resolves the **git worktree toplevel with a pure filesystem walk-up** (`ProjectKeyResolver` — never a `git` subprocess on the PTY read-loop thread; `.git` file counts, so linked worktrees group under their own checkout), and emits type 34 **only on change edges** (two dedupe anchors: cwd, then resolved key). Latched at the SNIFF point (the `lastProgress` idiom) and **re-asserted on reattach** alongside 23/26/27/31/32 — plus a latched type-33 `cwd` re-assert, making reattach cwd host-pushed instead of client-RPC-pulled.
- ✅ **Grouping/sort UI + machinery REMOVED (always By-Project, always creation order).** The sidebar hamburger (`SlateSortMenuButton`), `TabGrouping`/`TabSort` + their persisted `SettingsKey`s, `.byDate` bucketing, `.updated` recency sort (+ `tabLastActiveAt` stamps), `.manual` drag-reorder, and the whole client-side toplevel computation (`paneGitToplevel` cache + debounced `gitStatus` RPC sweep `refreshProjectKeysIfNeeded`/`fetchMissingProjectKeys`) are deleted. `paneProjectKey` = host-pushed key (persisted per-pane in `PaneSpec.projectKey`, so a cold relaunch renders the FINAL sections from disk — the brief cwd-fallback→toplevel re-bucketing flash on reconnect is structurally gone) → `lastKnownCwd` fallback until the first push. Sections order by first-appearance in `session.tabs` (creation order); rows within a section likewise.

## SSOT / week-long-stability / perf audit: 12 confirmed findings fixed (2026-07-11)

> The user asked for a full comprehensive audit: the server as single source of truth so a client reconnecting any number of times keeps the same state; the host runs long-running tasks for a week so stability must be guaranteed; performance unchanged; and terminal rendering must leverage libghostty's GPU rather than repeat herdr/tmux/zellij's mistakes. 10 lens-scoped finders (reconnect-terminal/workspace/video, longrun-host/client, races, perf-hotpath/rendering, todays-diff, wire-robustness) → 1 adversarial refuter per finding; 12 raw → 12 confirmed. All fixes test-first. GPU-invariant verdict: no server-side terminal-state creep found — the sniffer stays non-destructive, replay-only transforms stay replay-only.

- ✅ **Quit drains teardowns.** `applicationShouldTerminate` → `.terminateLater` + bounded 2 s `store.quiesce()` (`TerminationDrain` races drain vs timeout; re-entrant ⌘Q returns `.terminateCancel`). Close-a-busy-pane-then-⌘Q used to strand the host session in `DetachedSessionStore` with TTL NEVER and no client reference — a clean-quit reproduction of the wifi-flap orphan class.
- ✅ **Hook sinks keyed stably.** `AgentHookListener` entries are registered under the session's ORIGINAL env-baked paneID for its whole life (`hookPaneIDsBySession`); reattach refreshes the closure under the SAME key; every end-of-life (deliberate close, detached exit, TTL/overflow eviction via new `DetachedSessionStore.onEvicted`) unregisters. Detach deliberately does NOT unregister — detached-window hook folding stays live.
- ✅ **Journal fds released, files kept.** `ScrollbackJournalStore.release(sessionID:)` (flush coalescing buffer → close handle → drop dict entry, FILE KEPT as the restore source) on TTL/overflow/detached-exit; `delete` stays deliberate-close-only; released files age out by mtime in `sweep()`.
- ✅ **rebindRelay wake order.** Control wake stream + sender task are rebuilt BEFORE the output drain restarts/kicks — a detached-window sniffed title can no longer lose its wake (it would have sat in controlOut until the next live edge). Type 21 is now itself re-asserted on reattach (see "The title comes back", 2026-07-26), so a stranded title is recoverable rather than permanent — but it would still arrive late and out of batch order, so this ordering stands.
- ✅ **projectKey resolve off the read loop.** The `.git` stat walk (can block on a hung NFS/SMB mount) moved to `metadataQueue` with later-cd-wins stale-resolve drop; the read loop keeps only the batch scan + one `proc_pidinfo`. Plus a warm-up gate (OSC-7-only batches ignored until the first `.commandStatus` edge — plugin-manager cd noise can no longer persist a bogus section) and probe-beats-same-batch-OSC-7 at prompt edges.
- ✅ **metadataRequest flood bounded.** 32 in-flight cap per session; past the cap the host replies immediately with the builder's error status (always-replies contract kept) instead of queueing — the unwindowed control channel can no longer fan out unbounded lsof/git forks.
- ✅ **Video refusals are terminal + audible.** Host mux mint failure now sends `helloAck(accepted: false)` before forgetting the lane (was a silent drop → client hello-retried a black pane forever, re-enumerating host windows each try). Client `.rejected` emits new `Effect.sessionRejectedByHost` → `RemoteWindowModel.noteSessionRejected()` (teardown to picker + error) — deliberately NOT `sessionEndedByHost`, whose handler auto-rebuilds and would re-hello the doomed request forever.
- ✅ **Inspector re-arms on reconnect.** `LivePaneSession.reestablishInspectorOnReconnect()` from the store's `onReconnected` hook — the unchanged-status dedupe guard no longer starves the resubscribe after a flap during a long agent run.
- ✅ **Sidebar search stays memoized.** A non-empty query now filters the MEMOIZED rows (volatile match fields one memo-generation stale, same contract as row chrome) instead of bypassing `RailRowsMemo` into the O(panes)-per-tick direct builder.

## Tab cwd line stale after reconnect + busy-dot reveal threshold (2026-07-11)

> The user reported that after reconnect the cwd line in the tab bar stops updating — cd'ing into another folder keeps the old value — and asked that the tab's running-command dot have a threshold before it shows, made configurable with a 3s default.

- ✅ **Wire type 33 `cwd` is now host-gated SINGLE-SOURCE through the type-34 derivation (`MuxChannelSession.deriveProjectKey`) — no wire-format change, emission policy only.** Before: the live type-33 was the RAW sniffed OSC-7 riding the output FIFO (unfiltered plugin startup noise; nothing at all for OSC-7-less shells like Starship, whose tab cwd depended entirely on the completion-edge `cwd` metadata RPC), while the client dropped every type-33 arriving before that pane's first OSC-133;C — including the host's reattach re-assert, which is exactly why the tab's cwd line stayed stale across a reconnect. Now: an ACCEPTED cwd-truth change (post warm-up gate, post `lastCwdTruth` dedupe, probe-beats-stale-OSC-7) emits `.cwd` synchronously at the latch — BEFORE the async key resolve, so a hung mount can delay the section re-bucket but never the cwd line — and `ingestPTYChunk` strips the raw sniffed `.cwd` from the FIFO ride (it would otherwise arrive at drain time AFTER, and client-side overwrite, the probed truth). The client applies type-33 UNGATED (the `commandStartSeen` startup-noise gate is deleted — the host warm-up gate owns that filtering; the plugin-dir backstop stays at `setLastKnownCwd`/`setProjectKey`), restoring the 33/34 symmetry. Net: a `cd` updates the tab's cwd line host-pushed at the next prompt edge — every shell, no RPC dependency, including immediately after a reconnect; the completion-edge `refreshCwd` RPC remains as belt-and-braces.
- ✅ **Sidebar row TITLE frozen at first render — leaf identity keyed on the memoized fields it renders (the "New Pane" tab bug).** HW-reproduced on mac-studio (cua-driven ⌘T → chooser → Terminal, ctl-socket spec dump as ground truth): after the chooser resolved, the tree spec was fully correct (`kind: terminal, title: "Terminal", lastKnownCwd` set) and the memoized rows rebuilt (the row re-bucketed OTHER → its project section in the same render), yet the ROW VIEW kept rendering its FIRST-instantiation title ("New Pane"; the launch pane likewise kept its pre-cwd process-fallback title) — inside the sidebar's lazy container, a leaf whose own Observation deps fire re-renders with the `row` value it was CREATED with, so the perf-audit memo/leaf split (2026-07-10/11) silently froze every structural retitle (cwd landing, chooser resolve, disambiguation, rename) while subtitles/badges stayed live via `liveChrome`. Fix: `RailRow.leafIdentity` (pane id + title + kind + cwd) keys `.id(_:)` on the three leaf call sites (macOS row, WINDOWS row, iOS row) — a structural retitle now replaces the leaf; volatile chrome and focus-only changes keep the same identity (no churn). Verified at pixels pre/post-fix on the same flow. This — not the reconnect — is also what made the tab's folder-name title appear stuck after a `cd`: the regression shipped with the memo split and the user picked it up on the next reconnect/redeploy.
- ✅ **Busy-dot reveal threshold — the plain `commandBusy` dot shows only once a command outlives `tabBadge.busyDelaySeconds` (default 3 s, Settings → Shell → Tab Badge slider, 0 = immediate).** `WorkspaceStore.paneShowsBusyDot(_:now:)` (busy bit AND `paneCommandStartedAt` elapsed ≥ threshold; fail-VISIBLE when busy with no stamp) is the one thresholded `isBusy` input all three badge-resolution sites feed to `TabBadgeGating.resolve` (rail `chrome(...)`, `unseenAttentionPanes`, control-backend `tab list` — they may never disagree); the resolver itself stays pure/clock-free. The reveal repaint reuses the FIX-1 idiom: the command-START edge arms `flashDecayScheduler(threshold)` → one `completionFlashTick` bump, so a quiet long command's dot appears on its own without any polling timer. Raw `paneIsBusy` keeps driving the close guards — a busy shell confirms a close from second zero.

## Round-4 daily-driver audit: libghostty delta + terminal + remote-window — 12 confirmed findings fixed (2026-07-11)

> The user asked for a re-audit of libghostty and the important daily-driver features like terminal and remote window, fixing any problems thoroughly so the app is as stable, smooth, and low-latency as possible — like coding on the local machine rather than feeling remote. 8 domain finders (zig-delta + swift-binding on the main model, rest sonnet per the audit-cost directive) → adversarial refute per finding (2 lenses for critical/high); 14 raw → 12 confirmed, 1 refuted, 1 uncertain-but-fixed (iOS twin gate). All Swift fixes test-first with explicit file-ownership per parallel fix agent.

- ✅ **`update_mutex` extended to every render-thread mutator of updateFrame-visible state** (the round-3 mutex only closed updateFrame-vs-updateFrame; main-thread `ghostty_surface_draw` still raced the renderer thread's mailbox drain). `changeConfig` (frees `config.links`' arena + swaps `font_shaper` → UAF window while main-thread updateFrame is inside `renderCellMap`/`endFrame`), `setFontGrid` (its `markDirty` could be swallowed by updateFrame's `dirty=false` reset → garbage glyphs against the new atlas), `setScreenSize`, `setFocus`, and the two search-match swaps in `renderer/Thread.zig` (upstream takes NO lock there) now acquire `update_mutex` outermost. Lock order `update_mutex → state.mutex → draw_mutex` preserved globally — no guarded path holds the inner two when acquiring it. Delta 17→18 files (+37 lines); xcframework rebuilt universal, 3 slices re-verified (6/6 external-IO symbols each, 0 tmux/search).
- ✅ **build-libghostty.sh verifies EVERY slice** — the symbol gate passed if ANY slice had the external-IO symbols; a defective iOS slice in a universal build shipped silently. Now per-slice `ALL_OK` (a stale-cache-harvested slice fails the build at the gate, not later as client link errors).
- ✅ **Probe-view detach can no longer clobber the live surface** (`GhosttyTerminalView` macOS + iOS): a surface-less probe's `detach()` passed nil into `detachSurface`, whose unconditional else-branch cleared the LIVE pane's surface → visible freeze until an unrelated SwiftUI pass re-attached. Nil surface now makes no call; the identity gate is unchanged for real detaches.
- ✅ **⌘-hover link resolution cached by generation** — was a full viewport re-read (per-row `viewportTextRows()` through the C ABI, contending `renderer_state.mutex` with the VT parse) + full link re-detection per mouseMoved (60–120/s, main thread). Now cached keyed on `bytesReceived`/`viewportRevision`/cwd, invalidated on output/scroll/⌘-down-edge/detach; a pointer move with a valid cache is a pure cell hit-test. Soft-wrap-aligned per-row reads kept on refresh (E10). Covers hover, ⌘-click, and the right-click-menu path.
- ✅ **iOS render loop parity**: device `CADisplayLink` pauses on drained ticks / un-pauses at `requestPresent` (was a permanent 60 Hz main-runloop wakeup per idle pane); `makeUIView` no longer creates the surface eagerly — window-gated lazy creation in `didMoveToWindow`, display link starts windowed and dies un-windowed (probe passes can no longer spawn renderer+io threads, steal the on-screen surface, or leak an immortal display link). Simulator free-run branch untouched.
- ✅ **Scrollback journal sweep is periodic** — `sweep()` (14-day/256-file bounds on orphaned `.scrollback` files) ran exactly once at `HostServer.init`; a week-long hostd accumulated orphans unbounded. Now a daily-cadence task (injectable interval), handle cancelled in `stop()` (reaper-task pattern).
- ✅ **Detach-resume identity seeded at construction** — `makeClientSeeded`'s fire-and-forget `Task { seedResumeIdentity }` raced `performConnect()`'s connect job on the actor mailbox; a cold-launch multi-pane restore could silently start FRESH sessions, orphaning the detached ones. `SlopDeskClient.init(resumeSeed:)` sets sessionID/highestContiguousSeq/highestSeqFed synchronously before the instance escapes; the factory chain threads the seed through. Regression guard races init-seeding against concurrent actor traffic ×200.
- ✅ **[CRITICAL] Input button/modifier balance survives video reconnects** — every `hello` built a fresh `InputButtonBalance`, so a mouse-up/key-up after a transparent auto-reconnect (SCStream death, wifi flap) found nothing held → `suppress` → the terminating CGEvent never posted → host OS stuck in drag/modifier state (AppKit tracking loops hang; stuck ⌘ corrupts all input). `startLiveComponents` now seeds the new injector from the carried balance snapshot (taken in `teardownLiveComponents` under the identity guard); deliberate session END unchanged.
- ✅ **Packetize/FEC off the input path** — the encoded-frame pump ran MTU split + RS parity + wire-encode synchronously on the session actor; a keystroke arriving mid-packetize of a large IDR waited several ms for `CGEventPost`. New `PacketizeLane` actor owns packetizer+scheduler; `onEncodedFrame` awaits it (suspension → keystrokes interleave), then records LTR/ring/keyframe bookkeeping atomically on the session actor against the returned frameID before the send-lane feed — ring can never see a half-recorded frame, frame order preserved (single awaited caller), wire bytes byte-identity-pinned by test (incl. m==1 ≡ XOR).
- ✅ **Scroll residual can't strand** — the coalescer's trailing flush sat below the `guard !run.isEmpty` early-return, so a lost gesture-`ended` datagram stranded the residual until the next unrelated input. Accumulator fold extracted into pure `ScrollCoalescePlanner` (empty-run flush reachable, unit-pinned) + a one-shot idle flush after `scrollInjectInterval`; teardown cancels + clears.
- ✅ **Titlebar attention scan de-stormed** — `SlateTitlebar.body` evaluated the O(all-panes) `unseenAttentionPanes` walk TWICE per render and registered whole-dict Observation deps on every volatile per-pane dict (any pane's 1 Hz tick re-ran the always-mounted titlebar). Walk now single-bound inside the small `TitleMenuButton` leaf; the titlebar body has zero volatile-dict deps. (No memo type: unlike `RailRowsMemo`, the walk's output IS the volatile badge — a fingerprint would have to include it.)
- ✅ **Window title reads the process dict conditionally** — root `windowTitle` + titlebar `activeTitle` read `paneForegroundProcess` only when the title actually needs the process fallback (`RailStructureKey.titledByProcess`, extracted + reused); background panes' 1 Hz process edges no longer re-evaluate the root view.

## Host Windows rail (docs/45, 2026-07-11)

- ✅ **The right sidebar is a THIRD plain `NSSplitViewItem`, never `.inspector`** (unmount kills live video panes); mirror-twin anatomy of the left rail; default COLLAPSED (⌘⇧R — the deliberate re-take of the chord the removed Details panel freed); stability is the UX (alphabetical app sections, first-seen row order, restyle-in-place — never reorder on host focus/title churn).
- ✅ **Live feed = generation-anchored FULL snapshots over the video control lane** (types 16–18): `windowFeedSubscribe(knownGeneration)` every 2 s is simultaneously the poll, the push-subscription renewal (TTL 6 s host-side), and the loss-healing resync anchor — deltas REJECTED (idempotent latest-wins beats sequencing machinery on lossy UDP). Host differ: `CGWindowListCopyWindowInfo` at 1 Hz (4 Hz×3 s bursts on structural change, 0 Hz with no subscriber); title-only coalesces ≥2 s and never bursts. `SCShareableContent` stays hello/mint-only.
- ✅ **Rows anchor on APP ICONS; window content only at legible size** (user ruling: a too-small thumbnail is more useless than an app icon). Icon ladder: local Launch Services → disk cache (LRU 5 MB, magic-validated) → ONE wire fetch per bundleID (`appIconRequest` 19 → `blobChunk` 20 kind 0, host LRU'd chunks, single-flight). No monograms, no loading spinners — glyph fallback.
- ✅ **Phase-3 surface consolidation = ONE data source, not one view**: the push feed pre-warms the remote-window picker (`RemoteWindowModel.prewarm`) and answers `AppLaunchMonitor`'s poll while live; the picker/panel VIEWS stay (their pick/revalidate/manual-fallback flows are tested and battle-hardened — re-skinning them onto `HostWindowListView` was judged churn without user-visible gain; revisit only if the three surfaces drift).
- ✅ **Peek ships as a native NSPopover; AX accelerates, never carries** (Phase 4/5, 2026-07-11). Peek = Space/context menu → `windowPreviewRequest` (21) → kind-1 JPEG ≤48 KB, host-throttled (single-flight/window, ≤1 s reuse, ≤2 captures/s, sends paced 1 datagram/ms) because `SCScreenshotManager` shares WindowServer/GPU with the live encoders; FULLY-FORMED-ONLY (no spinner — a timeout shows nothing). Phase 5: `WindowFeedAXObserver` (dedicated thread — `dispatchMain()` has no CFRunLoop — 0.25 s messaging timeout) kicks the differ on frontmost-app window create/destroy/title/focus/miniaturize; the budgeted `AXMinimized` probe (≤3 stale pids/tick, 3 s TTL, `_AXUIElementGetWindow`) disambiguates minimized-vs-other-Space; the 1 Hz differ REMAINS the mandatory backstop. Hover-dwell peek DEFERRED pending HW evaluation; rail width persistence SKIPPED (autosave fights the collapse animation). HW-verified end-to-end against the live daemon: snapshot 27 real windows/2 chunks, 10-byte current-ack, Terminal icon PNG ×5 chunks, 640×360 JPEG peek ×4 chunks, and an UNSOLICITED push (gen 1→2) after a TextEdit launch with no renewal sent.
- ✅ **Off-screen windows need AX EVIDENCE to be listed** (user report 2026-07-11: filter out windows with no visible on-screen window — 16 of 27 live records were `.optionAll` phantoms: Chrome tab caches, panel services, `loginwindow`, `AutoFill`). Inclusion = `onScreen ∨ minimized ∨ axListed`, where `axListed` = the budgeted Phase-5 probe saw the window in its app's `kAXWindows` sweep (`WindowAXLedger`; a FAILED sweep folds nothing — stale beats absent). Alpha/`kCGWindowSharingState` were dead ends (all 1.0/1 on the live host). Accepted costs: a real off-screen window hides for the probe's first budgeted ticks (≤~4 s cold, junk-free beats instant), and apps whose AX under-reports other-Space windows keep those hidden until visited — the dimmed other-Space affordance stays for AX-listed ones.
- ✅ **Two NAME-based junk exclusions on top of the AX gate** (user report 2026-07-12: "Cua Driver"/"asverify" still listed). The AX gate can't catch them: "Cua Driver" (the cua automation agent's cursor overlay) is a REAL on-screen layer-0 window — transparent, full-display, nothing to stream → joined `excludedSystemApps`; Finder's App Store `asverify` receipt-verification window is genuinely in Finder's `kAXWindows` yet never renders → `junkTitlesByOwner` keyed (owner → titles), scoped to Finder so real Finder windows stay. Generic detection was rejected twice (alpha/sharing dead ends; "appHidden" would kill real windows like Parsec) — a curated name list is the honest tool for a curated-junk problem.
- ✅ **Rail rows are DRAG SOURCES onto the canvas** (user request 2026-07-12: drag a window from the sidebar into a pane). The drop reuses the pane-move ZONE LANGUAGE (slab+seam / dock rail) with insert semantics: pane edge band → `newRemoteWindowSplit(beside:axis:before:)` (splits the pane UNDER THE CURSOR, not the active one), container gutter → `newRemoteWindowAtRootEdge` (new pure op `insertPaneAtRootEdge` — mints a pane, so unlike the pane-move dock it works on a lone-leaf tab), pane centre / gaps → `newRemoteWindowTab` (the click verb; no swap exists for an insert, so the WHOLE canvas is a valid target — wash preview + chip make the fallback legible). Commit-on-release, exactly ONE store op (the pane-move rule).
- ✅ **The rail drag is AppKit END-TO-END — SwiftUI's DnD modifiers failed on BOTH sides** (live-verified on mac-studio, 2026-07-12, HID-event probes + a `registeredDraggedTypes` dump). A SwiftUI `DragGesture` + named coordinate space can't cross hosting views at all (rail and canvas are separate NSSplitView columns), so cross-column DnD was mandatory; then (a) SOURCE: `.onDrag` on a `SlateListRow` never lifts — the row shell's tap gesture claims the mouse-down before the drag interaction's threshold; (b) DESTINATION: `.onDrop(of: [customUTType])` never engages — SwiftUI's `_PlatformDraggingDestinationView` registers only `public.data`/`public.item`, AppKit matches `registeredDraggedTypes` by EXACT STRING so a custom-typed pasteboard is never delivered, and even co-advertised as `public.data` the internal routing never called `validateDrop`. Shipped shape: `HostWindowRowDragSource` (NSView event-tracking loop — ≥4pt = `beginDraggingSession` in-app-only, mouse-up = the row's click verb) + `HostWindowDropCatcher` (`NSDraggingDestination` registered for `com.slopdesk.host-window`, mounted topmost over the canvas, `hitTest` nil UNLESS `HostWindowDragSession.isDragging` — at rest it is invisible to every event). Payload rides the in-process `HostWindowDragSession` (pasteboard data is sealed until drop); the UTType is declared in the app's Info.plist (`UTExportedTypeDeclarations`). Follow-on: the overlay ALSO swallows the events SwiftUI `.onHover` rides, killing the row's hover plate — it senses hover itself (tracking area, hitTest-independent) and drives `SlateListRow` through a new `hoverOverride`; the rail row's hover gained an icon scale bump (1.12, the pane-move pill treatment) and dimmed rows wake to full strength under the pointer (colour/scale only — the frame never moves). The hover VERB HINT ("OPEN" / "FOCUS · n") was then REMOVED on user ruling (2026-07-12, judged to add nothing useful): it said nothing the click doesn't, and the tooltip already carries the long-form meaning — the streamed tab ordinal now holds the trailing slot hover or not.
- ✅ **The right rail is the open windows' TRACKER; the left rail is terminal-only** (user directive 2026-07-12: "left sidebar chỉ track terminal pane" — move remote-window tracking to the right sidebar). `RailRowsBuilder.rows` excludes `.remoteGUI` (the left "Windows" section + its iOS twin deleted — one pane no longer answers to two sidebars; the ⌘K palette enumerates panes itself, so window panes stay jumpable). The right rail's streamed row gained the tracker duties: FOCUSED-pane raised card (restyle-in-place, live-read in the leaf), click = `revealPaneTree` (tab switch + focus + badge auto-clear — the left-rail row-click rule), context-menu `Close Pane`. The streamed derivation was hoisted to `WorkspaceStore.streamedWindowPane(for:)` — the ONE rule behind the marker, the click verb, Open Quickly, and the drag commit.
- ✅ **Dragging an already-streamed rail row MOVES its pane — never a duplicate** (same directive: an open window's drag "counts as move from its old position to the new one"). `SplitContainer.commitWindowDrop` branches on `streamedWindowPane`: mint stays for unstreamed windows; streamed ones route to `breakPaneToTab` / new pure ops `WorkspaceTreeOps.moveLeafAcrossTabs` + `moveLeafToActiveTabRootEdge` (cross-tab moves — prune from the source tab, a sole-leaf tab closes outright, re-insert in the hovered tab; `PaneID` preserved so reconcile is a registry no-op and the live stream survives; same-tab delegates to the existing `moveLeaf`/`moveLeafToRootEdge`; cross-SESSION is a structural no-op — specs cannot leave their session's side table). Zone resolution borrows the pane-move source rules: spanned-edge docks suppressed, and the source's own rect resolves a new `.keep` zone (muted chip "already here", release = reveal only) — without it the `.newTab` fallback would EJECT the pane to a fresh tab when the user put it back down. Legibility: chip verbs read "move to new tab" / "move · split right", and the lifted pane wears the pane-move dashed outline. ⌘-click / "Open Another Pane" stay the sanctioned duplicate paths.

## Replay hygiene: zsh PROMPT_SP marks stripped from restored scrollback (2026-07-12)

- ✅ **`PromptEOLMarkStripper`** (user report: on client reconnect the scrollback shows stray `%` characters). Before every prompt zsh (PROMPT_SP + PROMPT_CR, default-on) emits the PROMPT_EOL_MARK — captured live as `\e[1m\e[7m%\e[27m\e[1m\e[0m` + SP×(COLUMNS−2) + `\r \r` — an overwrite trick that is WIDTH-DEPENDENT: correct only at the emission-time grid width. Replayed history spans many widths (panes resized/split since), so on cold reattach the fill wraps for real and every prompt grows a stray `%` line (or a `≫ %` tail). The stripper matches the cluster ONLY when it immediately precedes the shim's `133;D`/`133;A` (zsh's `preprompt` runs right before the precmd hooks — nothing else writes there, making false positives structurally impossible) and rewrites it width-independently: provably-at-column-0 clusters (previous non-zero-width byte is a newline, looked through SGR/EL/DECSCUSR/OSC) are EXCISED (the live render was invisible); mid-line/unknown clusters become one CRLF (partial line preserved, prompt on a fresh line, no mark). Composed LAST in `ScrollbackReplayTransform.make` (`SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS`, default-ON) — both the ring cold-reattach pass and the journal restore; live stream and un-acked tail stay byte-exact. Proven against every live journal on the host (29 files): 133/133 clusters removed, all `133;A` prompt anchors (block-jump counts) intact.
- ✅ **Adversarial review hardened the matcher (same day, 10-agent workflow, 2 confirmed findings).** (1) CRITICAL: with `unsetopt PROMPT_SP` (a real user customization the shim does not override) the pre-anchor bytes are genuine command output, and the bare-mark tolerance let the ordinary `progress: 100%␣␣␣␣\r` pad-to-clear idiom lose its literal `%` — fixed by requiring SGR wrapping on BOTH sides of the mark (zsh's promptexpand always emits both on a capable TERM; the dumb-TERM bare mark is a deliberate miss). (2) MAJOR: the unbounded prefix-SGR walk swallowed a reset the COMMAND wrote abutting the cluster, letting its colour bleed across the replayed prompt — fixed by replacing every matched cluster with `\e[0m` (+CRLF mid-line) instead of pure excision, which also restores the reset the cluster's own SGR cleanup applied live (pure excision silently dropped that state transition even in the base case).

## Replay hygiene: input-affecting terminal modes stripped from replay, net truth re-asserted (2026-07-13)

> User report: after using vim (nvim) in a pane, closing and reopening the client injects garbage into the shell — `zsh: command not found: 18M65` spam, plus `8;33;96;1452;1632t` at each reattach. Root cause (verified against the poisoned 18 MB journal): replayed history is EXECUTED by the fresh client terminal. nvim enabled in-band resize (`?2048h`) + kitty event reporting (`CSI >3u`) + mouse tracking at byte ~82 k of its run and disabled them 18 MB later — so for ~99 % of the multi-second replay the client is armed exactly as the TUI left it. `?2048h` makes ghostty emit a size report (`CSI 48;…t`) the instant it is processed, and any user scroll/click/keystroke mid-replay emits SGR mouse reports / kitty release events (`\e[<65;31;18M`, `\e[108;1:3u`) — all delivered as PTY input to a shell at a plain prompt, echoed, executed, and re-journaled (the journal recorded 6 such incidents). The disables arrive later in the replay, too late.

- ✅ **`TerminalInputModeStripper`** (`SLOPDESK_SCROLLBACK_STRIP_INPUT_MODES`, default-ON): a pure replay-side pass that removes the input-affecting set — DECCKM `?1`, mouse `?9/1000–1006/1015/1016`, focus `?1004`, bracketed paste `?2004`, in-band resize `?2048` (mixed-param DECSETs like `?1049;2004h` are rewritten, not dropped), and the kitty keyboard ops (push/pop/set, simulated as a stack) — while computing the NET final state a terminal replaying the raw stream would end at. Display state (`?1049/25/7/2026…`) passes through untouched.
- ✅ **Net truth re-asserted, per path.** The ring's cold-reattach pass (live session) appends `InputModeFinalState.reassertSequence` as the replay's last bytes: an all-TUIs-exited session nets to nothing (nothing armed, ever), a session still inside vim nets to vim's modes — mouse keeps working across the reattach, and the re-asserted `?2048h` makes the client send one fresh size report, which a live in-band-resize consumer wants. The journal restore (fresh shell after a daemon restart) does NOT re-assert — there is no TUI to serve, and the sanitize suffix stays all-off.
- ✅ **Pass ordering matters: the mode pass runs FIRST, on the raw stream.** The distiller reorders history (an open B→C span's bytes are flushed out of order or replaced by the committed `133;E` command line), which flips the computed net state — caught live against the real journal, where the post-distill order said bracketed-paste OFF while the live zsh prompt has it ON (that stale-order state is exactly what the client latched pre-fix).
- ✅ **`sanitizeSuffix` extended** (backstop for env-disabled raw replay + already-poisoned journals): now resets every mouse encoding, `?1004`, `?2048`, and pops/zeroes the kitty keyboard stack (`CSI <32u`, `CSI =0;1u`).
- Proven end-to-end against the real poisoned journal: post-transform replay contains zero armed sequences and ends with exactly the one correct re-assert (`?2004h`, the live prompt's bracketed-paste truth). The recorded junk ECHOES remain as inert display history.

### Follow-up, same day: mode 2031 + closed alt-screen segments (field screenshot after the first deploy)

> After the first deploy the user's cold client relaunch replayed the 18 MB journal and screenshotted the pane seemingly "stuck inside vim" with fresh `^[[?997;2n` garbage at the prompt. Two residual causes, verified against the live journal tail.

- ✅ **`?2031` joins the tracked set** (+ `?2031l` in the sanitize suffix): color-scheme notifications are report-on-enable exactly like 2048 — ghostty emits `CSI ?997;1|2 n` the instant the replay crosses `?2031h` (nvim enables it), and the report landed on the prompt as `^[[?997;2n`.
- ✅ **`AltScreenSegmentStripper`** (`SLOPDESK_SCROLLBACK_STRIP_ALT_SCREEN`, default-ON): a CLOSED alt-screen segment (`?1049h…?1049l`, `?47`/`?1047` variants) contributes zero cells to the final display — `?1049l` discards it — but a 4m44s vim session records ~18 MB of cursor-relative redraw churn that the cold reattach replayed through the wire and the client terminal: seconds of the pane visibly re-rendering stale vim frames at recording-time geometry (the screenshot), plus a wide transient-arming window. Closed segments are now dropped whole (mixed-param DECSETs keep their non-alt params); a segment still OPEN at end-of-stream is the live TUI's screen and is kept verbatim — that replay IS the repaint. Runs after the input-mode pass (raw-order net state, normalized params), before the distiller. Proven on the real journal: restore shrinks 18.3 MB → 89 KB with zero armed sequences and the alt content gone.

## Workspace prefix key: default ⌃B + Settings override (2026-07-14)

- 🔁 **RE-SCOPE (prefix default): the tmux-style workspace prefix defaults to ⌃B, not ⌃A.** The user runs neither tmux nor GNU screen inside SlopDesk panes, so ⌃B collides with nothing they use — while ⌃A is readline beginning-of-line, typed constantly at a shell prompt (the double-tap send-prefix made it *work*, but every jump-to-line-start cost two keystrokes). The single default lives in `WorkspaceBindingRegistry.defaultPrefixChord`; the store seed, `TerminalKeyInterceptor`, and `PrefixStateMachine` all read it, so the app monitor and the per-surface interceptors cannot disagree out of the box.
- ✅ **Prefix key is now user-configurable: Settings ▸ Key Bindings ▸ Workspace Prefix.** The override is `KeybindingPreferences.prefixKey` (additive within schema v3 — `decodeIfPresent` ⇒ an existing blob decodes `nil` = default; NO version bump, existing rebinds survive). Resolution is `WorkspaceBindingRegistry.resolvedPrefixChord` (validate-then-default: an unmappable or ⌃/⌥/⌘-less stored chord is discarded — a bare/shift-only prefix would swallow normal typing). The editor row records via the same `KeyCaptureMonitor` under a synthetic `workspace.prefixKey` recording id, rejects modifier-less captures (`isUsablePrefixKey`, keeps recording), Backspace clears to default; a set prefix flips `hasCustomizations` so Reset-to-Default covers it. **Live apply:** `PreferencesStore.applyKeybindings` fires the app-installed `PreferencesStore.onPrefixKeyApply` hook with the resolved chord → `WorkspaceStore.applyWorkspaceKeyPrefix` (re-points `workspaceKeyPrefix` + sweeps every materialized pane's `TerminalKeyInterceptor.setPrefix` — without the sweep an existing surface would keep arming on the old prefix, split-brain) and `WorkspaceKeyDispatcher.setPrefix`. At launch the hook is deliberately not yet installed for the init-time apply: the store + dispatcher are BUILT from the resolved prefix, so nothing is stale. Pinned by `PrefixKeyResolutionTests` (+ round-trip in `PreferencesTests`).
- ✅ **Bare follow-up = implied-⌘ (same day): `prefix, d` fires the ⌘D binding.** First hardware use surfaced that "⌃B D" did nothing: every workspace chord is ⌘/⌥-prefixed (the §5 conflict rule), so a bare armed key could never hit the table — the arm always ended `.disarmSwallow`. The armed branch of `PrefixStateMachine` now retries a ⌘-less follow-up as its ⌘ chord (⇧/⌥ carry through: `⌃B ⇧D` = ⌘⇧D split-down; `⌃B 1–9` = tab select falls out for free). The fold lives ONLY in the armed branch — an idle bare key stays normal typing (the load-bearing PTY guard) — and in the MACHINE, so the app monitor, the per-surface interceptors, and iOS all get it from one change. Resolution order while armed: explicit `[prefix, key]` sequence → the key as-typed → the implied-⌘ fold → tmux-faithful disarm-swallow. Also: `PrefixArmedChip` re-rendered on the shared `InstrumentChipShell` (`PREFIX · ⌃B`, the COPIED·N register) — the one live-mode chip now reads as the same instrument as the transient receipts.
- 🔁 **RE-SCOPE (same day): the prefix-armed indicator is a PANE MODE PILL, not a window-corner chip.** Two placements rejected on hardware: the bottom-leading window corner (a floating island far from the eye, popping over terminal content for <1 s) and the InstrumentChipShell restyle of the same corner (right register, still the wrong place — that shell is the RECEIPT family: COPIED·N / TAB CLOSED). The decisive observation: prefix-armed is a keyboard MODE — the same semantics as VI / READ ONLY / SECURE INPUT — and this app already has a home for those: the FOCUSED pane's top-trailing mode-pill stack. `PrefixArmedPill` (PaneStatusPills.swift) joins that family: keyboard glyph + the prefix chord in the accent tone with the accent hairline ring (`ViModePill`'s visual-selection ARMED treatment), appended LAST in the stack (appearing displaces no persistent pill), FADE-ONLY (sub-second state — a move transition reads as flicker; the CopyReceiptChip rationale), hit-transparent. Mounted on BOTH leaves (`TerminalLeafView` + `GuiLeafView` — the dispatcher swallows the prefix before the video pipeline, so the cue belongs on a focused video pane too), gated by the pure `PrefixArmedPill.shows(staticMirror:isFocused:armed:)` (focused pane only — an unfocused pane showing "armed" would lie about where the follow-up lands). The leaves read the SAME `OverlayCoordinator.prefixArmed` flag the dispatcher drives; only the view moved.
- 🔁 **RE-SCOPE (v3, user-directed): the prefix-armed cue is the TITLEBAR CENTRE chip's whole-label state swap — the pane mode pill is REMOVED.** The pane pill fixed the family-register complaint but (a) still didn't read as beautiful in situ and (b) had a structural hole the user hit immediately: a CHOOSER pane (terminal-or-window not yet picked) mounts neither leaf, so arming over it showed nothing. The titlebar centre (`TitleMenuButton`) is the one always-mounted, pane-kind-independent chrome slot: while armed, the whole `title ●` label crossfades to `⌨ ⌃B` (keyboard glyph secondary + chord in the accent tone) and back on resolve — a state swap of EXISTING chrome (no added ornament, no floating island, no layout travel; both layers share one ZStack so the chip never moves). `PrefixArmedPill` + both leaf mounts deleted; the dispatcher → `OverlayCoordinator.prefixArmed` seam is unchanged (third view over the same flag). Placement history: window-corner receipt chip (rejected — wrong family) → focused-pane mode pill (rejected — right family, wrong surface + chooser hole) → titlebar centre swap (current).
- 🔁 **RE-SCOPE (v4, restyle in place): the armed readout is the KEYCAP chip `[⌃B] …`, not `⌨ ⌃B` in the accent tone.** Same slot, same swap (the titlebar centre chip's whole-label crossfade); only the armed layer's voice changed after the accent take still read as ugly. Diagnosed off a headless render (new opt-in `SlateSnapshotRender.testRenderTitlebarPrefixArmed` — `TitleMenuButton` made internal for it, the full `SlateTitlebar` can't rasterise past its `HoverSensor` platform view): (a) the semibold MONOSPACED chord drew `⌃` as a cramped fallback caret — SF Mono has no menu-grade modifier glyphs; (b) the ⌨ SF-symbol was an icon riding text in a text-first bar; (c) the accent tone shouted over an otherwise all-grey strip (accent rationing). The restyle speaks the product's existing picture of "a key": the PALETTE's keycap register (system face small/medium — menu-bar-quality ⌃, primary tone on the raised plate + hairline) plus the vi-hint-bar's bare `…` "more keys" token for "awaiting the follow-up". No icon, no accent, nothing invented.
- 🔁 **RE-SCOPE (v5, user-directed): the prefix-armed cue lives in the CONNECTION CLUSTER — while armed, the ping readout crossfades to the `⌃B …` capsule pill; the titlebar centre-chip swap is REVERTED.** The keycap-in-the-title take still didn't read as beautiful; the user pointed at the ping cluster ("thay cục ping thành cái pill prefix"). It is the right home: the cluster is the chrome's one RUNNING instrument readout, always mounted in both sidebar states (footer while open, titlebar trailing while collapsed), so the cue stays pane-kind-independent without hijacking the workspace's identity label. `PrefixArmedPill` (ConnectionCluster.swift): the chord in the palette's keycap face (system, small/medium, primary — never mono, no icon, no accent) + the vi bar's tertiary `…`, in a CAPSULE on `raised` + hairline; the swap is a ZStack crossfade in place (zero-shift — the pill is narrower than the cluster), hit-testing follows visibility. The chord reads `WorkspaceBindingRegistry.resolvedPrefixChord` (live registry resolution — a Settings rebind shows with no threading). The scene `OverlayCoordinator` is now threaded EXPLICITLY into both hosted columns' environments (`SlopDeskSplitViewController` → `.overlayCoordinator(overlay)` on NavigatorColumn + ContentColumn) — the same "separate NSHostingController does not inherit the WindowGroup environment" reason `preferences` is threaded; the sidebar-footer mount depends on it. `TitleMenuButton` restored to its pre-swap form (private, title + one trailing complication). Snapshot lock: `SlateSnapshotRender.testRenderClusterPrefixArmed` (renders both mounts, resting beside armed, over a throwing-registry `AppConnection` double).
- 🔁 **RE-SCOPE (v6 refinement, user-directed): only the cluster's TRAILING metric swaps — the hostname stays; the pill is the bare `⌃B` capsule (the `…` suffix is dropped).** The whole-cluster swap blinked the host identity away and the `…` read as dirt next to the chord ("cái dấu ... sau ^B là gì đấy, nhìn xấu thế"). The swap now lives in `ConnectionCluster.trailingSlot`: ping / status word ↔ `PrefixArmedPill` (trailing-anchored ZStack crossfade — the right corner never shifts), hostname untouched. The slot is `fixedSize(horizontal:)` — the metric is a short instrument readout and must never truncate to `…`; the HOSTNAME is the row's designated truncator (regression caught in the `testRenderClusterPrefixArmed` render: the ZStack wrapper squeezed "disconnected" in the hugging mount).

## Copy-mode ceiling LIFTED: real vi cursor + keyboard-started selection via a fork ABI extension (2026-07-14)

- 🔁 **RE-SCOPE (lifts the E17 §317 ceiling): the "no programmatic char-select" ceiling was an ABI gap, not a design truth — the fork now exposes it, so copy-mode gains a REAL vi cursor and keyboard-STARTED visual selection.** E17 documented the ceiling honestly (`adjust_selection` could only EXTEND a mouse-anchored selection; `o` was a no-op; `y` fell back to mouse-selection-or-whole-scrollback) because the pinned libghostty fork had no set-selection C API. That was the only blocker: upstream v1.3.1 already has everything internally (`Screen.select`, the `ghostty_selection_s` point resolver `Selection.core()`, native selection rendering). Three new exports in the slim delta (`embedded.zig` + `ghostty.h`, same `renderer_state.mutex` discipline as `ghostty_surface_read_text`): **`ghostty_surface_set_selection(surface, ghostty_selection_s) -> bool`** (resolves the same tagged points as read_text, calls `Screen.select` — `rectangle` gives block-select for free; bypasses copy-on-select deliberately: an incremental keyboard selection must not spam the clipboard, the copy happens on `y`), **`ghostty_surface_clear_selection(surface)`**, and **`ghostty_surface_viewport_info(surface, ghostty_viewport_info_s*) -> bool`** (viewport top-left row in SCREEN coords + viewport rows/cols + total screen rows + the terminal cursor's screen position — the readback that makes a client-held cursor HONEST: every claim the overlay draws derives from libghostty truth re-read per keystroke, so the anti-jitter rule survives the lift).
- ✅ **The vi cursor is CLIENT state in SCREEN coordinates, re-clamped against fresh `viewport_info` on every key — selection RENDERING stays native libghostty.** `CopyModeState` gains a cursor (entry = the terminal cursor position from `viewport_info`); motions `h l 0 ^ $ w b e` (word/column motions read the cursor row's text through the seam), `j k` with viewport-follow (`scroll_page_lines:±n` then re-read — never a cached offset), `g G ⌃d ⌃u ⌃f ⌃b` page motions move cursor AND viewport, `[ ]` keep the prompt-jump then re-anchor the cursor to the landed viewport top. `v/V/⌃v` anchor AT the cursor and drive `set_selection` (anchor→cursor, line mode = full-row span, block = `rectangle: true`) so ghostty's own renderer paints the selection — no client-drawn selection rectangles; `o` swaps anchor↔cursor (the documented no-op is retired); `y`/Enter yanks the REAL range via the unchanged `read_selection` path (mouse-selection / scrollback fallback kept for non-visual yank). Esc leaves visual mode first (+ `clear_selection`), then exits. The cursor OVERLAY (block outline via `TerminalCellMetrics`, hidden when scrolled off-viewport, updated on key + scroll echo) is the one client-drawn element, and it only ever draws a position computed from the same-keystroke `viewport_info` readback. Scrollback eviction while in copy-mode can shift screen coords (we do not freeze the screen like tmux); the per-key clamp makes that degrade to a bounded cursor nudge, never an out-of-range selection.
- ✅ **Entry chord `⌃B, [` (tmux parity) as an EXPLICIT sequence on `view.copyMode`** — the implied-⌘ fold would resolve a bare armed `[` to ⌘[ = `cyclePanePrev`, so the sequence table (checked before the fold) is load-bearing here. ⌘⇧C + ⌃⇧Space stay as the resolving chords; the hint bar advertises the new motions (the `advertisedKeys` honesty surface grows with the ability, same rule that removed the dead `o` row).

## Persistence stability audit: same-UUID ghost teardown races + replay splice + SIGTERM (2026-07-14)

> The user asked for a careful re-audit of the persistence features (detach/reattach, scrollback ring + disk journal, replay transforms, client resume) for daily-driver stability. Five domain audits (detach lifecycle, HostServer+journal, replay transforms, transport replay, client persistence) → findings adversarially verified line-by-line before fixing. No wire change; golden byte-identical.

- ✅ **End-of-life teardown is now OWNERSHIP-GUARDED — a same-UUID ghost can never kill its live successor's persistence (the round's CRITICAL cluster).** Two convergent races minted a fresh session under a sessionID whose predecessor was still winding down: (a) the detach window — `handleLinkDown`/`recoverFailedRebind` remove the session from `muxSessions` and only THEN insert it into the store, and a reconnect's `channelOpen` landing in that gap claim-misses and spawns fresh (the known accepted residual); (b) claim-reap — `claim()` reaps a parked dead child and the fresh spawn follows, but the ghost's exit task fires its `onDetachedExit` closure seconds LATE (`awaitExitSentOrTimeout` up to 10s). Both shapes made `journal(for:)` hand the ghost's SHARED `ScrollbackJournal` instance to the successor — the ghost's teardown then `closeKeepingFile()`d it, and every later append by the LIVE pane was a silent no-op forever (plus interleaved writes while both lived, a stale `hookPaneIDsBySession` unregister killing the successor's agent-status routing, and a spurious `.none` fan clearing its working badge). Fixes, each independently sufficient: `spawnFreshShell` takes journal ownership via **`claimJournal(for:)`** (a cache hit = a ghost owner → rotate: flush+close the ghost's instance, vend a fresh writer appending to the same file — transcript continuous, ghost's later appends drop); **`release`/`delete` are instance-guarded** (only the map entry's own instance may drop/unlink it; delete's close+unlink now runs under the store lock so a racing re-vend can't be unlinked out from under its fd); **`DetachedSessionStore.remove` returns whether the caller WON the entry** and the detached-exit closure stands down when it lost (`claim` reports `.reapedDeadChild` distinctly so `spawnMuxChannel` fans the final `.none` + drops the ghost's hook key itself); **hook-sink entries carry an `owner` identity** so stale unregisters no-op. Failure-path hygiene: a fresh spawn that fails (spawn error / stopping) releases its just-claimed writer.
- ✅ **Replay backpressure is recompute-at-apply.** `nextSeq`/`acknowledge`/`setClientOnline` computed `shouldPauseDrain` under `replayLock`, unlocked, THEN applied to the gate — two independent tasks (reattach-backlog drain vs. tail acks) could land a stale value last, wedging the read loop paused with nothing left to ack (no future event recomputes) or overshooting the retained ceiling. `updateReplayBackpressure()` now serializes [read fresh truth → apply] under a dedicated apply lock; the last apply always reflects the latest state. (Stale "4 MiB" comments on the 64 MiB offline gate corrected across 7 sites while touching this.)
- ✅ **The ring/tail splice can no longer corrupt a split escape sequence.** PTY chunking can cut ONE escape sequence across the scrollback-ring / un-acked-tail boundary; the transform appended the input-mode reassert AFTER the dangling half — the client then aborted the split sequence (losing its toggle) and printed the tail's continuation as literal text, precisely in the reattach-into-live-TUI case the reassert exists for. `ScrollbackReplayTransform` now holds back a trailing incomplete escape (bounded backward scan) and re-attaches it after the reassert: `[transformed][reassert][dangling]` keeps the dangling half adjacent to its continuation.
- ✅ **XTSAVE/XTRESTORE (`CSI ? Pm s|r`) join the input-mode stripping.** They bypassed `TerminalInputModeStripper` entirely: a raw `?1000s … ?1000r` pair replayed from history re-arms mouse reporting mid-replay (the garbage-input class the stripper exists for, via the save/restore door) and desyncs the net-state simulation. Same strip/rewrite discipline as h/l, with per-mode save slots in `InputModeFinalState` (restore-without-save = initial value, off); bare `r` (DECSTBM) / `s` (SCOSC) stay untouched.
- ✅ **hostd handles SIGTERM like SIGINT.** Only SIGINT had a handler — `kill <pid>`, launchd stop, and system shutdown killed the daemon instantly with NO orderly drain. SIGTERM now routes through the same one-shot latch (verified live: `SIGTERM — shutting down` + clean exit).
- ✅ **Journal restore vs. sweep ordering + disk-pressure compaction backoff.** `spawnFreshShell` registers the live writer BEFORE reading the restore (the old order let a concurrent `sweep()` prune the file in the gap); a failed compaction (the `.atomic` rewrite transiently needs ~cap free space small appends don't) now sets a retry floor instead of re-reading the whole over-cap file on every subsequent append.
- 📌 **Verified-not-bugs worth recording:** the client’s resume-identity path is sound (seed is synchronous in `SlopDeskClient.init`, decode is all-or-nothing with a `.corrupt` sidecar, `resumeLastReceivedSeq` is deliberately ignored on cold launch); `MuxSubChannel.isFinished` covers every finish path; reconnect backoff is capped (20 attempts) with `.exit` terminal; `connection.close()`'s handler-install window is covered by the `stopping` discipline. Known accepted: offline pane-close is never re-signalled on reconnect (detached agent accumulates by design); bare `?47/1047` closed-segment drops can diverge cursor position when a program hand-writes them without the `ESC7/ESC8` smcup idiom (rare; documented here, not fixed).

## The Stage: terminals and streamed windows HARD-SPLIT into dedicated zones (2026-07-14)

> User-directed re-scope after a UX research round (IDE dock models, i3 master-stack, VMS main/sub-stream, remote-desktop clients): usage is terminal-dominant, yet every new-pane gesture paid a chooser tax, and mixing streamed windows into the terminal split tree meant neither zone could be read at a glance. New model: **glance left = terminals, glance right = everything else.** The split tree becomes TERMINAL-ONLY; streamed remote windows (and future webview/editor content) live in the STAGE — a dedicated tabbed zone docked between the canvas and the host-windows rail, one active stream decoding at a time.

- 🔁 **RE-SCOPE (reverses WS-C 2026-06-25): the in-pane chooser is RETIRED — ⌘T / ⌘D / the `+` button mint a `.terminal` pane DIRECTLY.** The chooser was designed when the two kinds were peers; with windows moving to the Stage, a kind question on the hot path has no second answer left. `PaneKind.chooser` is removed with the same decode bridge discipline as the retired `web`/`claudeCode` kinds (a persisted `"chooser"` decodes to `.terminal`); `InPaneChooserView`, `choosePaneKind`, and the chooser skip in reconcile go with it. cwd inheritance is unchanged (the direct terminal mint rides the same `newTab`/`splitActivePane` placement + inherit path the chooser rode).
- 🔁 **RE-SCOPE (amends the v6 "pane = terminal-OR-window" reset): the split tree is KIND-HOMOGENEOUS (terminal-only).** A `Session` gains a `stage` — an ordered list of stage pane ids + an active id, persisted additively (older files decode to an empty stage). Stage panes keep `PaneID` + `PaneSpec` identity (specs invariant widens to tree leaves ∪ stage), so `LivePaneSession`/`PaneSessionHandle`/reconcile/persistence machinery is reused wholesale — reconcile materializes tree ∪ stage. A legacy persisted tree that still carries `.remoteGUI` leaves REPAIRS them into stage tabs on load (validate-then-repair, no schema bump).
- ✅ **Single-active-decode (v1: one stream at a time).** Only the ACTIVE stage tab has `isVideoActive`; switching tabs pauses the previous stream (freeze, never unmount — the `.inspector` lesson) and resumes the new one. `liveVideoCap` semantics keep enforcing the ceiling; background stage tabs cost zero decode.
- ✅ **Ingress redirect: every remote-window open lands in the Stage.** `newRemoteWindowTab/Split/AtRootEdge` collapse into `openWindowInStage(windowID:title:appName:)`; the host-windows rail's click/drag verbs and the palette rows route there; `streamedWindowPane` resolves against the stage. The system-dialog monitor's auto-spawn becomes an auto stage tab (same ephemeral, never-persisted rule). The pane-canvas drop affordance for host windows is retired — the canvas accepts no video content anymore.
- ✅ **Stage zone UX (Zed-dock rules):** own tab strip, collapses to zero width when empty (no placeholder), auto-reveals when a window opens or focus jumps into it, divider drag resizes with the same resize-scrim/settle discipline as panes, no leaf-frame animation. Input capture unchanged: click into the stream focuses it (accent ring), terminal keeps default keyboard ownership.

## Full-desktop pivot: the Stage AND the host-windows rail are RETIRED — one mixed-kind split tree; the GUI pane streams a whole DISPLAY (2026-07-14)

> User-directed re-scope after hands-on with the Stage + compact rail (both shipped earlier the same day): the dedicated right-hand zones didn't earn their keep — the ask is one split tree whose panes can open multiple content kinds, remote viewing as a FULL DESKTOP stream (per-window picking retired as the primary flow, so the rail has nothing left to list), terminal stays the default kind with its chords untouched, and each non-terminal kind gets its own dedicated shortcut instead of any chooser.

- 🔁 **RE-SCOPE (reverses "The Stage", same day): the split tree is MIXED-KIND again — the stage domain is deleted.** `Session.stagePanes`/`activeStagePane`, `WorkspaceStore+Stage`, `StageZone`, `stageFocused`, the tree↔stage disjointness invariant, and the legacy-video-leaf→stage migration all go. The revert is cheap because the hard split never touched the rendering seam: `PaneContainer` still routes `.remoteGUI`/`.systemDialog` leaves to `GuiLeafView`, whose `isVisible`-driven `activateVideo`/`deactivateVideo` + `liveVideoCap` (default 2) is the decode-concurrency gate — single-active-decode was Stage tab policy, not a pipeline constraint, so it simply stops being enforced. Persisted stage panes fold back into the tree as tabs on load (specs invariant returns to `Set(specs.keys) == leafIDSet()`). `addSystemDialogPane` mints a tree tab again (same ephemeral, never-persisted rule).
- ✅ **KEPT from the Stage round (user-confirmed): the chooser stays retired.** ⌘T / ⌘D / ⌘⇧D / the `+` button mint a `.terminal` pane DIRECTLY — the default kind gets the hot path; every other kind gets its own explicit shortcut. No kind question ever returns to the new-pane gesture.
- ✅ **NEW pane kind `.desktop` — the remote-viewing pane is the WHOLE display, not a window.** ⌥⌘N (free; the dead canvas table's "new remote pane" precedent) opens a Desktop tab; split-with-desktop variants are palette rows (no chords — splits stay terminal-first). The desktop pane reuses the entire remote-GUI pipeline (`GuiLeafView`, `RemoteWindowModel`, decode admission, input encoder): only the TARGET changes.
- ✅ **Wire: display-targeted hello (video control types 22–24).** `listDisplays` (22, session-less like `listWindows`) / `displayList` (23, `[DisplaySummary]`: displayID, point size, isMain) / `helloDisplay` (24: protocolVersion, requestedDisplayID — 0 = main display, viewport). `helloAck` is reused unchanged — `windowBoundsCG` carries the DISPLAY's CG bounds and `captureWidth/Height` its point size, so the client decode/aspect-fit/input math is untouched. Golden vectors spliced (hand-merge, never regenerate-over).
- ✅ **Host: a display session is a window session minus the window machinery.** `SCContentFilter(display:excludingWindows: [])` with NO `sourceRect` crop, `captureScale` from the display's backing scale; NO window parking, NO `WindowGeometryWatcher`, NO AX raise (`CGEvent.post(.cghidEventTap)` is already display-global — for whole-desktop input the raise step is simply skipped); `InputInjector` gains a display-scoped mode (no pid/windowID; same pure affine `CoordinateMapping.windowPoint` fed `CGDisplayBounds`); `CursorSampler` samples against display bounds; `resizeRequest` acks at the fixed display size (the client letterboxes — a desktop pane never resizes the host's display). Virtual-display parking stays for per-window sessions.
- 🔁 **RE-SCOPE (reverses docs/45 + the same-day compact flavour): the host-windows rail is DELETED.** With full-desktop as the viewing mode there is no window list to keep on screen. Gone: `HostWindowsColumn` (+ hover card, icon caches), `HostWindowDropAffordance` + the `SplitContainer` drop-catcher, the third `NSSplitViewItem` + rail divider snap/compact machinery, `WorkspaceChromeState.hostRailCollapsed/hostRailCompact`, ⌘⇧R (`toggleHostWindows` leaves the action vocabulary; the chord returns to the free pool), `Slate.Metric.hostRail*`, both rail settings keys, docs/45. **KEPT-SHARED (load-bearing beyond the rail):** `HostWindowFeed` + wire types 16–18 (Open Quickly's Host rows + `AppLaunchMonitor`'s layout auto-switch), `HostWindowIdentity/Info`, the picker prewarm. Types 19–21 (icons/previews) lose their client callers and stay dormant on the codec — wire untouched.
- 🔁 **RE-SCOPE (amends the 2026-07-12 "right rail is the tracker" ruling, premised on the rail existing): per-window streaming survives as a SECONDARY path via Open Quickly (⌘⇧O Host rows) — restored tree-tab mint (`newRemoteWindowTab`), no rail, no drag-drop grammar.** Tracking a video pane = the tab strip + ⌘K/Open Quickly, like any pane; the left navigator lists video leaves again (the exclusion existed only because the right rail carried them).

## Pane detach ↔ reattach: any pane pops out into its OWN macOS window (2026-07-16)

> User-directed: any pane kind (terminal / desktop / remote window / future kinds) can detach into a separate OS window — e.g. a full-desktop stream on a second monitor — and reattach as a pane. DISTINCT from the pruned 2026-07-03 floating panes (in-app overlay cards over the tiled tree): satellites are real `NSWindow`s, the tiled split tree remains the only IN-WINDOW layout.

- ✅ **Domain: `Session.detached: [DetachedPane]` (pane + originTab), additive v11 field — NO schema bump** (`decodeIfPresent`; encoded only when non-empty so detach-free files stay byte-identical). The specs invariant widens to `Set(specs.keys) == leafIDSet() ∪ detachedIDSet()`; `normalizingSpecs()` repairs the list (tree-shadowed / duplicate / spec-less entries drop). Ops: `detachPane` (closePane-shaped prune that KEEPS the spec + records the origin tab), `reattachPane` (origin tab when alive, else active tab, root-edge insert, fresh-tab fallback; KEEPS `PaneID`), `closeDetachedPane` (the real close — `closePaneTree` routes detached ids here so a PTY exit in a satellite can't zombie).
- ✅ **Liveness: reconcile's desired set = `tree.allPaneIDs() ∪ detachedPaneIDs()`** — the registry handle (PTY stream / video session) SURVIVES the detach; only the view remounts (terminal ring-replays into a fresh surface; a video pane re-hellos — the brief reconnect is the accepted v1 cost). A session that still owns satellites SURVIVES its last tab closing (`cascadeAfterTabRemoval` guard) — an explicit `closeSession` still drops its satellites (destructive by intent).
- ✅ **Windows: pure AppKit (`SatellitePaneWindowController` + marker class `SatellitePaneWindow`), NEVER a second SwiftUI `WindowGroup`** — the single-workspace-window machinery (windowBox / chord dispatcher / close gate) is untouched; satellites never mount `.introspect`. The coordinator diffs `store.detachedPanes` ⇄ windows; each root hosts the SAME `PaneContainer` leaf UI with scene env re-injected (hosting roots inherit nothing). Window key-state drives `isFocused` (video input forwarding follows the key window).
- ✅ **Close = REATTACH, never destroy:** the satellite's `windowShouldClose` folds the pane back and vetoes; the coordinator's diff performs the one real window teardown. Menu Close Window targets the KEY window (a key satellite closes itself, not the hidden main window). Detach NEVER routes the close-confirmation surface (non-destructive).
- ✅ **Persistence v1: satellites do NOT restore as windows across relaunch** — the launch restore re-docks every persisted detached pane into its tab (`redockingDetachedPanes()`, launch-ONLY: it must never run op-internally or it would undo a live detach). A quit/crash while detached loses nothing.
- ✅ **Chords/menu/palette:** `.detachPane` ⌥⌘P ("pop out"), `.reattachAllPanes` chord-less; registry-driven menu rows + palette verbs; iOS routing is a no-op (no NSWindow).

## Trackpad gestures: swipe-back / pinch / smart-zoom are KEY TRANSLATIONS, not gesture synthesis (2026-07-16)

> User-directed ("two-finger swipe-back doesn't work in the browser; audit every common macOS
> gesture"). Root cause is architectural, probe-verified on the host (six CGEvent field variants,
> real link-click history): browsers refuse synthetic swipe input — Chromium's `HistorySwiper`
> requires real `NSTouch` data or `trackSwipeEventWithOptions:` (both reject CGEvent-posted
> scrolls), Safari behaves identically — and gesture events (`magnify`/`rotate`/`smartMagnify`)
> have NO public constructor at all. Full audit table: doc 05 §8.

- ✅ **Swipe back/forward → HOST-side translation.** `SwipeNavRecognizer` (pure, pinned) watches the
  scroll stream `InputInjector` already posts; a COMPLETED flick (≤ 400 ms began→ended, ≥ 120 pt,
  ≥ 3× horizontal dominance, momentum never participates) fires ⌘[ / ⌘] — but ONLY into apps where
  that chord means history (`SwipeNavPolicy` allowlist: browsers + Finder; `SLOPDESK_SWIPE_NAV_APPS`
  extends). In an editor ⌘[ is outdent — an allowlist miss means "scroll only", never a text edit.
  Scroll forwarding itself is untouched (the page still rubber-bands natively). `SLOPDESK_SWIPE_NAV`
  default-ON. Decision-at-gesture-END is the safety property: a browser arbitrates scroll-vs-navigate
  per page (it knows the page is pinned); a remote host can't, so the flick SHAPE gates instead —
  slow horizontal content pans (spreadsheets, wide code) never qualify.
- ✅ **v2 (same day, HW feedback "even a hard swipe doesn't register"): momentum-CONFIRMED lift +
  UDP loss tolerance.** The v1 on-glass-only gate rejected exactly the most emphatic swipes: the
  harder the flick, the SHORTER the fingers stay on glass — most displacement arrives in the
  momentum tail v1 ignored, and a long deliberate swipe blew the 400 ms budget instead. v2 keeps
  the lift decision (thresholds retuned: ≤ 450 ms, ≥ 80 pt fires outright) and adds a second path:
  a dominant quick lift ≥ 24 pt ARMS a 250 ms coast window; momentum deltas confirm at ≥ 120 pt
  combined. Momentum still only ever CONFIRMS what the on-glass segment armed — a rejected pan's
  tail navigates nothing. Loss tolerance: a lost `began` is synthesised from the first continuous
  `changed`, a lost `ended` from the first momentum event (v1 silently dropped the whole gesture —
  the input channel is send-once UDP). Reorder/dup hardenings: a 250 ms post-fire REFRACTORY
  (a reordered on-glass straggler after the fired `ended` must not re-fire off the gesture's own
  momentum tail = back two pages), and synthesised candidates never ARM (a straggler from a
  REJECTED pan + the pan's momentum tail must not navigate). `SLOPDESK_SWIPE_NAV_TRAVEL` scales
  the threshold family; `SLOPDESK_SWIPE_NAV_TRACE` (≤ 2 stderr lines/gesture) exists so the NEXT
  "didn't register" report comes with the real travel/duration/dominance numbers.
- ✅ **v3 (same day, HW feedback "can't swipe slowly like native"): SLOW tier — commitment replaces
  speed past the flick boundary.** The trace receipts showed exactly what v2 rejected: 681 pt and
  246 pt swipes at 16× dominance, refused for taking ~500 ms. Natively a page-swipe works at ANY
  speed — the peel tracks the fingers and commits at release — so an absolute duration gate is the
  wrong model. Past 450 ms the lift now fires on COMMITMENT instead: ≥ 2× travel (160 pt default,
  scales with `SLOPDESK_SWIPE_NAV_TRAVEL`) and ≥ 4× dominance (harder than the flick's 3× — a long
  gesture gives the hand time to wander; field traces of deliberate slow swipes run 16×+), with NO
  upper duration bound (natively you may drag, hold, and release whenever). Slow lifts never ARM —
  momentum confirmation stays a flick mechanism, so long content-pan tails still can't navigate.
  The accepted trade-off: a decisively-horizontal ≥ 160 pt content pan inside an allowlisted
  browser (wide sheets/maps) now navigates — remote recognition cannot see the page's scroll
  state, commitment is the only proxy, and the daily workload is docs/code where pages don't
  scroll horizontally. `SLOPDESK_SWIPE_NAV_SLOW=0` is the escape hatch (restores the v2 gate).
  What CANNOT be reproduced remotely: the gradual peel-while-dragging visual — translation fires
  a discrete ⌘[ / ⌘] at lift; only the trigger acceptance is native-like, never the feedback.
- ✅ **v4 (2026-07-17, HW feedback "still not native" WITH every post-v3 gesture firing 8/8 in the
  trace): CLIENT-side swipe-peel feedback — the v3 "cannot be reproduced" claim was true only
  host-side.** With acceptance solved, the remaining gap was the dead glass: native shows the page
  reacting from the first millimetre and commits with an animation; ours showed nothing, then the
  page teleported one beat after lift. The HOST can never animate a ⌘[ — but the CLIENT owns both
  the real trackpad events and the video layer. So the client now mirrors the exact same
  `SwipeNavRecognizer` (moved to `SlopDeskVideoProtocol`; new `liveCandidate` read-only view) over
  the stream it forwards, and `SwipePeelPlanner` maps it to feedback: a rubber-banded ≤ 32 pt
  video-layer nudge (`tanh`, a NUDGE by design — the remote may genuinely scroll horizontally, a
  full slide would double-move), a chevron chip whose ring fills toward the live tier's threshold,
  a solid flip + ONE trackpad haptic at "release now navigates", a confirm pulse + 180 ms ease-home
  on fire (the real page streams in underneath the beat), an ease-home on any reject/reroute.
  Feedback must never lie: it shows only from the arm line (≥ 24 pt decisively horizontal), and it
  is gated by a NEW host push — `SwipeNavStatusMessage`, cursor-socket type 3 (golden
  `swipeNavStatus`; `SwipeNavStatusKicker` fans out on frontmost activation + 2 s heartbeat,
  window sessions resolve their own target app) — carrying eligibility AND the host's
  travel/slow knobs so the mirror always predicts the host's actual verdict (`SwipeNavHostConfig`
  is the single env parse). No push (old host) ⇒ no overlay. The nudge is the one animated
  `videoLayer.transform` write in the client (a channel `layoutVideoLayer` never touches);
  the chip is a SwiftUI overlay via `VideoPaneControls` (never an NSView subview over Metal, flat
  fills only — no material over the `CAMetalLayer`), non-spring reveal curve per the design
  system. Pinned by `SwipePeelPlannerTests` + `liveCandidate` pins in `SwipeNavRecognizerTests`.
  Three review-confirmed hardenings landed with it: the daemon kicker is retained by the
  transport's `onReceive` closure (the `do` scope exits right after the non-blocking listener
  start — a scope-local would deallocate in seconds and silently kill the push); `viewPoint`
  subtracts the live peel shift (presentation value, so the ease-home beat compensates too) —
  the same render/input coupling the zoom/pan inverse preserves; and a mid-gesture direction
  reversal concludes the old chip before re-showing (same-identity SwiftUI content would have
  animated the alignment flip as a full-pane slide).
- ✅ **v4.1 (2026-07-17, HW feedback "still not native" AGAIN, post-v4): the chip never showed —
  the daemon's `NSWorkspace.frontmostApplication` is a first-access-frozen snapshot.** A runtime
  probe (new diagnostic `slopdesk-swipestatus-probe`: mints a real display session against the
  RUNNING daemon, primes the cursor flow, reports arriving type-3 datagrams) proved the push path
  alive but `eligible=false` on every beat — with Chrome demonstrably frontmost. In a run-loop-less
  daemon NSWorkspace's snapshot freezes at its first access (any thread; a side-by-side experiment
  showed `CGWindowListCopyWindowInfo` tracking live app flips while NSWorkspace never moved), so
  the kicker was pushing the launch-time Terminal forever, and the injector's identical read was
  correct only by first-access luck (frozen wrong ⇒ ⌘[ misfiring as OUTDENT into a later-focused
  editor). Fix: `HostFrontmostApp` — a fresh-per-call WindowServer query (first layer-0,
  visible-alpha window's owner, front-to-back; pure scan unit-pinned) used by ALL THREE frontmost
  reads (status kicker, fire-path allowlist, raise skip-check), NSWorkspace demoted to fallback.
  Kicker gained a change-only `SLOPDESK_SWIPE_NAV_TRACE` line — the path had zero observability,
  which is how the freeze shipped invisibly. Standing rule: NEVER read NSWorkspace state in the
  daemons; static audit REFUTED this exact suspect because both paths shared one API — only the
  runtime probe exposed the freshness split, so freshness bugs get probes, not audits. (The
  `didActivateApplication` observer also never fires under `dispatchMain()` — eligibility flips
  ride the 2 s heartbeat alone, an accepted ≤ 2 s arming latency.)
- ✅ **v5 (2026-07-17, immediately after v4.1): native-SCALE peel — the page follows the fingers,
  and the commit choreography masks the navigation round trip.** v4's deliberately-timid 32 pt
  nudge could never read as native next to Safari's full-page drag. The peel now slides the video
  layer ~1:1 under the fingers with a soft `tanh` knee into a 45 %-of-pane cap (initial slope 1 —
  finger-locked; the cap keeps the reveal from reading as a detached card) behind a flat
  near-black CURTAIN + an 18 pt edge shade covering exactly the pane-edge gap rect. The curtain
  sits ABOVE the metal layer, not beneath: the video layer is an OVERSIZED pan-offset sublayer,
  so translating it exposes ADJACENT PAGE CONTENT — a below-layer backdrop stays covered and the
  peel would read as a content pan (caught pre-review from `layoutVideoLayer`'s
  `origin.x = -panOffset.x`). Pane-coordinate rect, blind to the pan origin; an opaque flat
  CALayer sibling is the allowed shape (the law bans NSView subviews and materials/blur —
  MERIDIAN flat, the chip stays the affordance). The planner now hands the view RAW travel — the mapping is
  geometry-dependent and belongs where the bounds live. On fire, the outgoing page FREEZES: one
  NV12→RGB conversion of the frame on glass (pacer's `lastRenderedImageBuffer`, once per fired
  navigation, never on the 120 Hz path) becomes a plain snapshot layer at the current offset, the
  live layer returns home invisibly beneath it (same pixels), a ~280 ms hold lets ⌘[ land and the
  destination page stream in, then the snapshot slides off in the swipe direction — Safari's own
  snapshot-swap trick; a slow navigation degrades to revealing the old page (v4's teleport, now
  with motion), and no-frame-yet degrades to the plain ease-home. The double-motion objection that
  justified the nudge is accepted as a trade: pages that also scroll horizontally see the local
  slide on top of their own pan, in exchange for native feel everywhere else — same class of
  trade-off as the v3 slow tier, same escape hatch. **Slow tier dominance is now GRADUATED**
  (`slowCommitmentFires`, shared verbatim by lift + live mirror): ≥ 4× at 2× travel as before, OR
  ≥ 2× once travel is overwhelming (≥ 3× fire = 240 pt) — the field 856 ms Σ=(355,−155) deliberate
  swipe (2.3×, rejected by the whole-gesture 4×) now fires, because native decides the axis at
  onset and forgives later wobble. Widened trade accepted: a ≥ 240 pt strongly-horizontal (≥ 2×)
  slow drag in an allowlisted app navigates; sub-240 pt wobbly drags and sub-2× diagonal
  explorations still reject (pinned both sides).
- ✅ **v6 (2026-07-17, HW verdict on v5: dragging the whole pane looks ugly — wanted feedback
  that does NOT affect the image): the video image NEVER moves — feedback is the edge chip +
  haptic only.** v5 was the first peel the user actually SAW (v4.1 unblocked the status push),
  and the on-hardware verdict rejected the concept, not the tuning: Safari peels the PAGE, but
  a remote pane is a window onto a whole desktop — translating the streamed image reads as
  dragging the pane itself, and no cap/knee fixes that. All image-motion machinery is REMOVED
  (not gated): the tracking `videoLayer.transform` write, the curtain + edge shade, the commit
  snapshot choreography (NV12→RGB freeze + hold + slide-off), the pacer's
  `lastRenderedImageBuffer` accessor, and the input-mapping peel-shift compensation.
  `SwipePeelPlanner` simplifies back to chip-only verdicts (`.show(SwipePeelChipState)`; raw
  `travelX` dropped — nothing geometry-dependent left to map). What remains is the v4
  affordance grammar, strengthened so the chip still lives with the finger without touching a
  pixel of video: the chip EMERGES from its pane edge with progress (tucked ~12 pt at the arm
  line, fully out at commit), ring fill → solid + haptic tap at "release now navigates",
  confirm pulse on fire (the pulse alone now spans the inject→stream beat the snapshot used to
  mask). Recognizer, host fire path, status push, and the graduated slow tier are untouched —
  client-only, no wire change.
- ✅ **Pinch → CLIENT-side ⌘= / ⌘− ladder; smart zoom → ⌘0** (`PinchZoomKeyPlanner`, 0.2
  magnification/step, ≤ 3 steps/event; `SLOPDESK_PINCH_KEYS` default-ON). Rides the existing key
  path — NO wire change anywhere in this round.
- ❌ **REJECTED: private gesture-event synthesis** (Hammerspoon/Calf-Trail `TouchEvents` byte-blob on
  type-29 events) — works in Safari/Preview but confirmed broken in Chromium apps, macOS-fragile,
  and against the native-first discipline. ❌ **Rotate, force-click/pressure, Quick Look**: dropped
  (no universal equivalent / not faithfully synthesisable). ❌ **3/4-finger system gestures**: the
  client's own WindowServer consumes them before any app sees an event — host equivalents stay
  reachable as keystrokes (⌃↑/⌃↓/⌃←→) via immersive capture.

## Trackpad gesture audit batch: graduated commitment surface + fire-landing gate + feedback fixes (2026-07-17)

A field audit over 320 real lift decisions (per-gesture trace, one daily-driver session) plus an
adversarial multi-agent review of the whole gesture stack. The dominance gate proved essentially
perfect (204/204 rejects were true vertical scrolls); every real miss sat on a THRESHOLD CLIFF, and
two host-side robustness holes surfaced on the way. All changes below; no wire change anywhere.

- ✅ **Slow tier becomes a graduated commitment SURFACE** (`SwipeNavRecognizer.slowRequiredTravel`,
  shared verbatim by lift + the client mirror). ONE joint interpolation replaces both step
  cliffs, endpoints unchanged: the band's cheap-end ANCHOR eases along the seam fraction
  (450 → 700 ms: dominance 3× → 4×, travel 80 → 160 pt); at/above the anchor the requirement is
  the anchor's travel, below it interpolates linearly toward the fixed 2× floor @ 240 pt. Fixes
  both field misses: 839 ms Σ=(170,45) 3.8× (old step: 240 required; now ~169) and 550 ms
  Σ=(−131,25) 5.2× (old: +2 ms past the window ⇒ double travel; now ~112) — both were eaten and
  immediately retried. ⚠️ The first cut combined a duration ramp and a ratio band with
  `Double.minimum`; the adversarial review numerically proved the independently-gated branches
  FOLD along their crossing (at 3.5× the requirement jumped 120 → 180 pt across ~2 ms — a new
  cliff, and a chip-committed-then-host-rejects window). Only a JOINT surface is cliff-free; a
  dense continuity + ratio-monotonicity property test now pins it. Checked against the whole
  log: both eaten swipes flip to FIRE, zero of the 204 true scrolls do. Same trade-off as
  v3/v5, same escape hatch (`SLOPDESK_SWIPE_NAV_SLOW=0` kills the whole tier, grace included).
  Travel-reject traces now name the interpolated requirement the candidate actually faced.
- ✅ **WINDOW-pane fire gate: the chord must LAND where eligibility was judged.** The ⌘[/⌘] chord
  posts at the HID tap — it reaches the OS key-focus holder, not the pane's app; the old check
  asked only "is the PANE's app navigable" against a static bundle id. Firing while another app
  holds focus would outdent/indent in an editor. Now: pid>0 sessions re-check live focus
  (`HostFrontmostApp.frontmostPID()`) at fire time — mismatch suppresses the chord (traced) and
  kicks the raise chain so the immediate retry lands. The false doc-comment invariant ("lands
  there regardless of frontmost") is corrected. And the STATUS PUSH mirrors the same gate
  (`SwipeNavHostConfig.eligibleWindowTarget`: navigable AND frontmost, ≤2 s stale like the
  display path) — review-caught: without it the chip commits + haptics for a fire the host
  silently swallows, exactly the "affordance never lies" breach the type-3 push exists to
  prevent.
- ✅ **`HostFrontmostApp.bundleID()` NSWorkspace fallback DELETED** — it reintroduced the exact
  frozen-snapshot bug this type exists to fix, on precisely the no-layer-0-window paths (bare
  desktop, lock transitions) where it would fire. `nil` now flows into `isNavigable`'s nil ⇒ false:
  fail CLOSED (no chord, chip dark) beats fail-frozen.
- ✅ **Confirm pulse actually spans the nav round trip.** The v6 pulse claimed ~520 ms but the
  `.opacity(confirming ? 0 : 1)` played entirely inside the ambient 150 ms curve — the remaining
  ~370 ms held an invisible chip. The confirming chip now DIMS to a hold (35 %) instead of
  vanishing, then the existing clear task fades it out: pulse → dim hold → fade genuinely covers
  the 150–400 ms inject→capture→stream beat (the only fire acknowledgement v6 has). The chip
  overlay also gains `.allowsHitTesting(false)` (review-caught, house convention for overlays
  atop the Metal surface): a click at the pane edge during the now-visible hold must reach the
  remote window, not the chip.
- ✅ **Scroll route PINNED per gesture** (`ScrollRoutePinner`, pure): remote-vs-canvas is decided
  at began/mayBegin and held through the momentum tail — a mid-gesture focus flip no longer
  reroutes inertia into the other destination. `inputEnabled` stays a LIVE gate (read-only lock
  stops host relay immediately); phase-less wheel ticks keep per-event routing.
- ✅ **Smart-zoom ⌘0 gated per app** (`PinchZeroPolicy`, client-only): ⌘0 in Xcode is a navigator
  toggle, not "actual size" — known-unsafe app names skip the translation
  (`SLOPDESK_PINCH_ZERO_UNSAFE_APPS` extends; empty/desktop appName fails open; ⌘=/⌘− stay
  ungated — they are correct zoom chords in editors too). `RemoteWindowDescriptor` gains a
  client-seam `appName` (not wire) to carry the picker's app name to the view.
- ✅ **Reduce Motion respected in the chip**: tuck emergence + scale pulses collapse to in-place
  fades under `accessibilityReduceMotion`; ring fill, committed state and the haptic stay (they
  are information, not motion).
- ✅ **Allowlist: pre-release browser channels completed** (Edge Beta/Dev/Canary, Opera
  Next/Developer, Vivaldi Snapshot) — the list already carried every other browser's channels.
- ✅ **Swipe-nav regime BANNER** under the existing trace flag: one line per injector naming the
  threshold family (travel/slow/grace/band/refractory), so a field log spanning restarts/deploys
  self-describes which recognizer produced each verdict (two pre-slow-tier lines in the audit log
  were identifiable only by their stale message format).
- ✅ **Test debt**: planner-layer refractory pin (chip cannot re-show inside the host's 250 ms
  swallow window) and `SwipeNavPolicy.fireTravel(fromEnv:)` clamp/reject-to-default pins (the one
  parse keeping host fire and client mirror in sync — and the `UInt16(fireTravel)` crash guard).
- ❌ **REJECTED (audit findings judged not worth acting on)**: momentum arm/confirm path unused in
  320/320 field lifts — it is a defensive net for tail-heavy flicks, keep as is; client-mirror vs
  host UDP-loss desync — real in theory, negligible on the WireGuard LAN, and a fix needs wire
  seq numbers; a "navigation in flight" spinner state beyond the dim hold — wait for HW feedback
  on the hold first.

## Swipe-nav history gate: the chip only shows when the browser can actually navigate (2026-07-17)

HW report: with the browser's Back/Forward buttons DISABLED (empty history in that direction), a
drag still raised the chip, filled it, committed, haptic'd — then nothing happened. The recognizer
docs claimed page state "is invisible remotely — commitment is the only proxy left". An AX probe on
the live host disproved half of that: history AVAILABILITY is readable; only page-content state
(edge position, scrollability) remains invisible.

- ✅ **Host reads canGoBack/canGoForward via the Accessibility API** (`HostNavHistory`,
  daemon-side — videohostd already holds AX trust for the raise chain). Two strategies, probed on
  real browsers:
  - **Menu key-equivalent path** (default): find the menu items whose key equivalent is ⌘[ / ⌘]
    (`AXMenuItemCmdChar`, cmd-only modifiers) and read `AXEnabled`. Locale-independent and
    semantically exact — it asks "would the chord we are about to send do anything". Chromium
    (CommandUpdater) updates these EAGERLY: probe-verified live flips on navigation, no menu open.
  - **Toolbar-identifier path** (preferred when present): buttons with `AXIdentifier`
    `BackButton`/`ForwardButton` — Safari's autoenabled menus validate LAZILY (probe: after a
    background navigation the History menu still said Back disabled while the toolbar button had
    already flipped to enabled), but the toolbar pair is what the user SEES, updates live even in
    background, and carries stable identifiers.
  - Elements are cached per pid (full scan 25–180 ms cold, off-main, 0.1 s messaging timeout,
    bounded walk that skips `AXWebArea`); a cached `AXEnabled` re-read costs ~0.05 ms, so polling
    is effectively free. Rescan on pid change or invalidated elements; any failure ⇒ UNKNOWN.
    ⚠️ Review-caught: a pid-only cache serves the wrong WINDOW's history for toolbar pairs —
    Back/Forward is per-window state there, and window A's buttons keep reading successfully
    (live elements, no AX error) after focus moves to window B of the same app, so the wrong
    flags would persist with historyKnown=true for the app's whole lifetime. The pair now
    remembers the window it was scanned from and `CFEqual`-checks it against the app's current
    focused window, rescanning on mismatch; menu pairs are exempt — app-global and
    focus-following by construction. ⚠️ Perf-audit-caught: that currency check is NOT the
    ~0.05 ms CFEqual — fetching the focused window to compare against is a live IPC round trip
    (probe: 1–6 ms), and per-beat it cost 0.4–2.4% of a core into Safari-family targets at
    4 Hz forever. It now runs only on FORCED beats (~2 s heartbeat + app activation), so an
    intra-app window switch can serve the old window's flags for ≤2 s — bounded and cosmetic
    (fire is ungated; a closed window still fails `readEnabled` and rescans next beat), unlike
    the unbounded staleness the check exists to kill. Runtime proof (unit tests can't touch
    AX): `slopdesk-navhistory-probe`.
- ✅ **Wire: `SwipeNavStatusMessage` grows one flags byte** (type-3 goes 5 → 6 bytes: bit0
  canGoBack, bit1 canGoForward, bit2 historyKnown; golden `swipeNavStatus` hand-merged, doc 20
  §9.6). UNKNOWN ships as historyKnown=0 and the client FAILS OPEN — non-browser allowlist
  targets, denied AX, or an app with neither menu nor toolbar pair behave exactly as before this
  change. Freshness: the kicker ticks every 250 ms and pushes on CHANGE (history flips on every
  navigation — a 2 s-stale "can't go back" right after clicking a link would eat the most common
  swipe); every 8th tick stays an unconditional heartbeat, preserving the 2 s loss self-heal.
- ✅ **Only the AFFORDANCE is gated, never the fire.** A dead-direction candidate never shows the
  chip (and a mid-gesture flip retracts it), but the host still fires the chord on a qualifying
  swipe: ⌘[/⌘] into a browser that cannot navigate is a validated-menu no-op, so NOT suppressing
  is strictly safer — a stale-disabled read can cost feedback, never a real navigation, and the
  dangerous direction (chip hidden while nav happens) needs the state to flip DURING the ~300 ms
  swipe. Escape hatch: `SLOPDESK_SWIPE_NAV_HISTORY=0` (host) reports UNKNOWN ⇒ pre-gate behavior.
  ⚠️ Review-caught, twice at the client's `.retract` sink: the gate relabels EVERY qualifying
  event of a dead-direction gesture to `.retract`, which (a) re-published nil-over-nil ~80×/
  gesture through the pane's `@Published` chip state, and (b) a double-back at history end — new
  gesture inside the previous fire's 520 ms confirm hold — wiped that hold, bypassing the
  confirming-chip exemption that only guarded the status-push path. `.retract` now clears only a
  visible NON-confirming chip (the planner resets `showing` at commit, so a confirm hold is the
  only live publish a `.retract` can coexist with — its pending clear task ends it).
- ❌ **REJECTED: per-app freshness trust list** (gate only browsers proven eager) — the toolbar
  path already covers the one probed-lazy browser (Safari), fail-open covers the rest, and a
  curated list is config surface that rots.

### Perf audit of the gate (2026-07-17)

Live-daemon profile (Chrome frontmost, worst normal case): whole daemon 0.7–0.8% CPU / ~80
wakeups/s; the kicker was ~1.4% of wall (mostly blocked IPC), dominated ~4:1 by the 4 Hz
`CGWindowListCopyWindowInfo` over the AX reads. Adversarial review (5 lenses, per-finding refute)
confirmed 3 real drains and refuted 10 (fan-out serialization, two-browser cache thrash,
MainActor/frame-present contention, client publish storms — v8 net-REDUCES client publishes).
Fixes, none touching the wire:

- **Zero-session tick gate**: with no live session the kicker returns before the WindowServer/AX
  reads (`VideoMuxSessionRegistry.hasSessions`) — the idle daemon is the COMMON state and was
  paying the whole 4 Hz loop for an audience of zero. Fresh sessions still bootstrap off the
  ≤2 s forced beat.
- **Early-stop frontmost query**: `frontmostPID()` decodes window records one at a time (toll-free
  NS views) and stops at the first elected layer-0 window instead of deep-bridging every
  on-screen window's record each tick (~30% of the query's samples; scaled with open windows).
- **Currency check throttled to forced beats** (see the ⚠️ above).
- **AX walk wall-clock deadline (1 s) + per-element 0.1 s timeout stamping**: budgets bounded
  call COUNT, not duration, and elements copied out of a walk (children/windows) carry the ~6 s
  framework default — a mid-walk beachball could stretch one rescan to multi-second latch-held
  stalls (kicker frozen for ALL sessions). Cached pair elements are the same stamped refs, so
  every later `readEnabled` is capped too. Truncated scan ⇒ UNKNOWN, fail open.

## Free pane drag: one grab-handle gesture moves a pane anywhere — across tabs, into a fresh tab, out to its own window, and back (2026-07-17)

The pane grab-handle drag could only rearrange the CURRENT tab (swap / re-split / dock). Getting a
pane anywhere else took keyboard verbs (⌃⌘T break-to-tab, ⌥⌘P detach) — and merging a satellite
back landed it wherever `reattachPane`'s origin-tab default chose, never where you pointed. The
domain layer already spoke cross-tab (the orphaned rail-drag ops `moveLeafAcrossTabs` /
`moveLeafToActiveTabRootEdge` — deleted UI, surviving tested ops); the ONE drag gesture now reaches
all of it:

- ✅ **Destination superset** (`PaneDragDestination`): inside the canvas the existing zones apply
  unchanged; past the hosting-view edge the drag resolves a SIDEBAR ROW (move BESIDE that row's
  pane, its tab revealed — `moveLeafAcrossTabsTree`), the drag-only **New-Tab slot** pinned above
  the sidebar footer (`breakPaneToTab`), or — released outside the main window — **tear-off**: the
  pane detaches into its satellite window opened AT THE DROP POINT (placement handed to
  `SatelliteWindowsCoordinator` through the drag coordinator, replacing the centre-cascade for
  drag-born satellites). Sole-leaf panes get the handle too (their exits are exactly these
  external targets); their New-Tab drop reads `.none` — breaking a lone-leaf tab out is the
  identity op.
- ✅ **Merge-back is the same gesture from the satellite**: a hover-revealed grab strip at the
  satellite's top edge drags with INSERT semantics — over the canvas every leaf is edge-band only
  (band 0.5, no swap, no dead centre — `PaneDragResolver.insertZone`), the gutter docks full-span,
  sidebar rows / New-Tab work as above — via three new PaneID-preserving ops
  `reattachPane(beside:)` / `(toActiveTabRootEdge:)` / `reattachPaneToNewTab` (reattach still
  no-ops sooner than crossing a session's spec side table or breaching `maxDepth`).
- ✅ **Why a coordinator, not SwiftUI DnD**: sidebar | content are separate `NSHostingController`s
  and satellites are separate windows — no coordinate space or `.onDrop` crosses those seams (the
  docs/45 lesson). `PaneDragCoordinator` is the rendezvous: targets register LAZY screen-rect
  providers (a weak-NSView closure each — nothing publishes per layout), the drag publishes only
  destination TRANSITIONS (`@ObservationIgnored` cursor), and hit-testing is the pure
  `PaneDragResolver` over plain rects (row hits clipped to the list viewport so LazyVStack's
  mounted-but-scrolled-away rows never shadow a target; no window frame ⇒ never tear off on a
  guess). Row highlight / slot / canvas landing preview are cheap observation leaves; past the
  canvas clip the cursor affordance is a borderless non-activating `NSPanel` chip (AppKit-moved
  per frame, SwiftUI-swapped per transition) speaking the same capsule voice as the in-canvas
  ghost chip.
- Every path commits ONE store op on release and keeps the `PaneID` — reconcile stays a registry
  no-op, so the PTY / video stream survives every hop (tab ↔ tab is pure geometry; tab ↔ satellite
  remounts only the view).

## Free pane drag, round 2: spring-loaded tabs, edge auto-scroll, keyboard parity (2026-07-17)

The v1 gesture could land a pane on any VISIBLE target; this round makes the hidden ones reachable
mid-drag and adds the keyboard twins.

- ✅ **Spring-loaded tab reveal** (Finder-folder style): dwelling a live drag ~500 ms on a sidebar
  row SELECTS that row's tab, so the drag can continue into the newly revealed canvas and drop at a
  precise split. The reveal rule is pure (`PaneDragCoordinator.springLoadTabIndex` — only a
  background tab of the active session fires; the active tab's own rows and detached-pane rows
  never churn selection). The dwell re-arms per row transition, and the fire re-checks the live
  destination so a row the cursor already left can't switch tabs late.
- ✅ **Cross-tab canvas drop for tree drags**: after a spring-load the source pane's tab is hidden,
  so the visible canvas resolves with INSERT semantics against the coordinator's pushed active-tab
  layout (exactly the satellite case — no swap, no self-exclusion) and commits with the CROSS-TAB
  ops (`moveLeafAcrossTabsTree` / `moveLeafToActiveTabRootEdgeTree`). The source tab's moveLayer
  stays MOUNTED while it owns the live drag (hidden at opacity 0) — unmounting it would destroy
  the grab handle whose gesture is still tracking. The active tab's landing preview reuses
  `ExternalDropZonePreview`, now keyed on "source not in these frames" instead of origin.
- ✅ **Sidebar edge auto-scroll**: a drag parked in the list's top/bottom 44 pt band scrolls rows
  into reach (ramped by band depth — `PaneDragResolver.autoScrollStep`, pure + pinned; bands shrink
  on short lists so they can't overlap). A 30 Hz timer does the stepping — the pointer stream alone
  would stall the moment the hand stops — and each tick re-resolves the destination because the
  rows moved under a stationary cursor. The `NSScrollView` is captured lazily by a reader INSIDE
  the scroll content (`enclosingScrollView` can't be reached from the viewport reader outside).
- ✅ **Palette parity**: "Move Pane to New Tab" joins the fixed catalog under TAB — deliberately not
  PANE: section order beats score across sections, and a `.pane` row matching "new tab" would
  shadow the exact "New Tab" verb. "Move Pane to Tab N" rows are DYNAMIC (one per non-active tab,
  `MovePaneToTabSource`, snapshotted per palette open like the jump-to source; destination resolved
  by stable TabID at accept time). Row titles are position-based ("Move Pane to Tab 2") because
  every fresh pane is titled "Terminal" — title-based labels rendered indistinguishable twins; the
  live pane title rides the subtitle.
- ❎ **Dropping onto ANOTHER satellite window stays a tear-off at the drop point** (deliberate):
  satellites are single-pane by design, so "merge into that satellite" has no model to land in —
  a new window exactly where the user let go is the honest outcome. Revisit only if satellites
  ever host split trees.
- ❎ Cross-SESSION drags and iOS stay out of scope (the sidebar lists the active session only; iOS
  has no pointer drag).

## Audio streaming: host app audio rides the media socket as channel 6 (2026-07-17)

Audio was deferred at design time ("no per-window audio" — 07 §Phase 4, 08 Q5) on a framing that
research now narrows: ScreenCaptureKit's `capturesAudio` on a window-filtered stream delivers the
whole APP's audio, not the window's. Per-window stays impossible; per-app is enough for a coding
tool (one IDE/browser window ≈ one app), so the deferral lifts with reduced scope. Latency research
in 11 §7 (#13/#14, action item 10) already names the levers; this decision applies them with one
substitution forced by the pure-native-Swift rule.

- ✅ **Capture: SCK `capturesAudio` on the session's existing SCStream** (48 kHz stereo,
  `excludesCurrentProcessAudio`; a second `addStreamOutput(.audio)` on its OWN sample-handler
  queue). Same TCC bucket the video grant already covers, same lifecycle/teardown as the stream it
  rides. Capture is configured whenever the host gate (`SLOPDESK_AUDIO`, default-ON) allows;
  ENCODE+SEND run only while the client has opted in — the toggle never reconfigures the live
  SCStream. ❌ REJECTED: Core Audio process taps (macOS 26 added `bundleIDs`/`processRestoreEnabled`)
  — a second capture stack with its own TCC prompt, and the tap's all-zero-buffer failure is still
  live in 26.5 forum reports. Revisit only for audio-without-video sessions.
- ✅ **Codec: AAC-ELD via AudioConverter** (480-sample frames = 10 ms @ 48 kHz, ~128 kbps stereo,
  `kAudioConverterEncodeBitRate`). ❌ REJECTED: Opus — 11 §7 #13 assumed it, but
  `kAudioFormatOpus` encode via AudioConverter has years of unresolved corruption reports (Apple's
  only working recipe: mono/CBR forum code, unchanged through the 26 SDK), and libopus violates
  "only C = CSlopDeskSIMD". AAC-ELD is the same family FaceTime ships. Escape hatch:
  `SLOPDESK_AUDIO_CODEC=pcm` (s16le raw, ~1.5 Mbps on LAN, zero codec risk/latency) — the wire
  config packet carries the format ID, so the client follows whatever the host sends.
- ✅ **Transport: `VideoChannel.audio = 6` on the media socket, sent IMMEDIATE** — never through
  `VideoSendLane`/`sendPaced` (the cursor precedent: a keyframe burst must not head-of-line-block a
  200-byte audio frame; conversely 100 small datagrams/s cannot hurt video pacing). One datagram
  per audio frame (`[u32 seq][u32 hostSendTsMillis][u8 flags][u16 len][payload]`, BE,
  validate-then-drop); flags bit0 marks an in-band CONFIG packet (format ID + sample rate +
  channels + AAC magic cookie, re-sent ~1 s) so decoder bring-up needs no extra control round-trip
  and survives loss.
- ✅ **Control: wire type 26 `audioControl(enabled)`, client→host, in-session** (streamSettings
  twin: host SM applies only while `.streaming`, client stores the wish and re-sends after every
  accepted re-hello, host resets to OFF on session mint). Default OFF — audio is per-pane opt-in
  from the footer toggle.
- ✅ **Playback: raw output AudioUnit (HALOutput / RemoteIO) + own jitter ring** (11 §7 #14: small
  IO buffers), render callback pulls; target depth ~2 frames, underrun fills silence, high-water
  drops oldest. **Audio never waits for video and video never waits for audio** — no
  cross-stream sync (11 §7 #6: PTS fire-and-forget; the ~10–20 ms audio-behind-glass skew is far
  under lip-sync threshold). Host clock rides `hostSendTsMillis` uncompared to client clocks, same
  contract as video.
- ❎ **No audio FEC in v1** (header reserves flags bits): the link is WireGuard LAN, concealment is
  frame-sized silence, and an RS block over K×10 ms frames adds more delay than the jitter ring it
  would protect. Revisit with `FECScheme` reuse if Wi-Fi loss proves audible.
- ⚠️ macOS 26.0 shipped Core Audio capture regressions (fixed in 26.1) — audio work is
  verified/shipped against 26.1+.

## Latched video-pane modes: client-owned, persisted with the workspace (2026-07-21)

- ✅ **Problem:** detaching a pane to a satellite window (⌥⌘P) silently dropped immersive
  system-key capture and the stream fps/bitrate overrides — they were `@State` on `GuiLeafView`,
  so the remount minted fresh view storage while `viewportLocked`/`audioStreamEnabled` (already
  model-owned with injector-`didSet` re-asserts) survived.
- ✅ **Fix = extend the proven model-owned-wish pattern, then persist it.** `RemoteWindowModel`
  now owns `immersiveDesired` + `streamFpsCap`/`streamBitrateCeilingBps`; the settings sink's
  `didSet` re-asserts a non-auto override into every fresh session (detach remount, re-hello,
  relaunch alike); the view auto-re-engages the CGEventTap from the wish (focused + injectable +
  AX-trusted only — never a prompt from a passive remount, and a plain unmount no longer clears
  the wish). All five latched modes persist in the additive TARGET-keyed
  `TreeWorkspace.videoModesByTarget` (`VideoEndpoint.modesKey`: a desktop pane keys by display, a
  window pane by its owning app — ids recycle, titles churn) — deliberately NOT pane-keyed: a
  close-tab → reopen-the-same-target mints a brand-new PaneID/spec, so pane-keyed storage dies
  with the tab (the first cut stored `PaneSpec.videoModes` and lost exactly that case). The store
  seeds the model at materialization AND on every endpoint commit (re-pick / display switch /
  rebind re-seed the NEW target's saved modes; the view syncs the immersive tap to wish changes
  both ways); entries normalize away when toggled back to default.
- ❌ **REJECTED: host as the single source of truth for these modes.** (a) Immersive is a
  client-LOCAL CGEventTap — the host cannot own another machine's keyboard routing. (b) The video
  host is deliberately per-session ephemeral (`userFPSCap`/audio reset on every `.startCapture`;
  the wire contract is "client re-sends its wish after every accepted hello") — host-side
  durability would need a persistent per-pane identity the host doesn't have (PaneID/workspace
  is a client concept) and would fight the reset-on-mint discipline. (c) A second client
  (iPad/macbook) viewing the same host must NOT inherit the first client's per-pane view prefs.
  The host-authoritative re-assert precedent (terminal types 23/26/27/32) covers HOST-owned
  facts; these are client wishes. No wire change; `close()`'s runtime resets never write the
  persisted intent (an app-quit teardown routes through `close()`).

## Reconnect while a live inline TUI (Claude Code) runs: transform EVERY cold-replay domain (2026-07-22)

- ✅ **Problem (field report):** reconnecting a client while Claude Code was running broke the
  pane wholesale, and cold reattaches replayed minutes-old churn "for a while" before settling.
  Measured on real journals: a 2 MiB transcript with Claude live carried 13,426 synchronized-
  output repaint frames; the existing transform pipeline left 260 KiB / 2,255 frames because the
  churn is INLINE (never enters the alt screen — `AltScreenSegmentStripper` can't see it) and
  lives in an OPEN command span (the distiller passes it verbatim). Worse, the transform only
  ever ran on the scrollback RING: the un-acked tail replayed raw, and the detached-window
  bytes live in the out-FIFO (sequenced at drain time, never in the ReplayBuffer at reattach),
  so up to the 64 MiB detached budget of raw absolute-positioned repaint frames shipped to a
  FRESH grid — stale geometry shredding the pane until Claude's next repaint.
- ✅ **Fix 1 — `SyncUpdateFrameCollapser`** (`SLOPDESK_SCROLLBACK_COLLAPSE_SYNC`, default-ON;
  runs after the alt-screen strip, before the distiller): drops `?2026h…?2026l` frames that
  repaint in place. Kept: frames that scroll content into history (LF/IND/NEL/`CSI S/T`),
  viewport-global effects (RI/RIS/`2J`/`3J`/DECSTBM), alt-screen transitions, OSC `133;` marks,
  piggybacked opener/closer params, and ALWAYS the stream-final frame (newest widget state
  until the post-reattach SIGWINCH repaint). Real-journal result: 2 MiB → 2.1 KiB with the
  final frame + net input-mode reassert intact. Accepted gap: autowrap-only scrolling inside a
  frame is invisible without a grid emulator — sync-frame TUIs disable autowrap per frame.
- ✅ **Fix 2 — cold replay transforms ring + un-acked tail as ONE stream**
  (`ReplayBuffer.replay(after: 0)`): a fresh client (`lastReceivedSeq == 0`) has rendered
  nothing, so there is no byte-exact continuity to protect. The re-chunk's LAST message always
  carries the top tail seq (else a shrinking transform strands un-acked bytes against the
  256 MiB pause gate forever — the ack anchor is emitted even when the clean output is empty).
  Warm reconnects (`lastReceivedSeq > 0`) keep the raw tail byte-exact, unchanged.
- ✅ **Fix 3 — cold reattach transforms the detached out-FIFO backlog**
  (`rebindRelay(transformDetachedBacklog:)`, set by `performReattach` iff the client presented
  seq 0): the chunk prefix is snapshotted under `fifoLock`, transformed unlocked (splice range
  stays valid — only the not-yet-restarted drain moves `fifoHead`; producers append after),
  spliced back as one chunk carrying the coalesced sniffed control, and the queue-gate
  accounting is rebalanced by the size delta (a leaked residue would wedge the read loop).
- ✅ **Segment-boundary independence is what makes three domains safe:** each stripper treats
  an unmatched close as defensive passthrough and an unmatched open as live-and-kept, so a
  frame/segment cut at a domain boundary (ring│tail│FIFO) degrades to "kept verbatim", never
  corruption; the input-mode reassert appears at each domain's end and later domains override
  earlier ones — the final assert is the true net state.

## Sync-input armed with no indicator = the "panes leak into each other" bug (2026-07-22)

- ✅ **Field diagnosis: the cross-pane "input/output leak" between two same-project panes was the
  per-tab synchronized-input feature (⌘⇧I / palette "Sync Input to All Panes") armed with ZERO
  surfacing.** The host-side identity plumbing was audited clean end-to-end (composite
  `(connectionID, channelID)` session keying, exclusive `DetachedSessionStore.claim`,
  attached-elsewhere refusal, monotonic `ChannelTable` ids, per-channel journal claim/rotation —
  no cross-pane path exists). The byte-level evidence was in the two panes' scrollback journals:
  the SAME keystroke-by-keystroke echo and the SAME final command executed in BOTH shells (one
  `exit 0`, one `exit 1`), plus an SGR mouse burst + XTWINOPS window report that ran AS A COMMAND
  in the sibling. The 2026-06 decision above claimed the armed state was "surfaced in the tab
  bar + pane status bar" — that indicator did not survive the v6 UI reset; `syncInputTabs` had
  no reader outside the store. An invisibly-armed fan-out mode is indistinguishable from a
  transport-layer leak to the user — armed state must be loud, everywhere it acts.
- ✅ **Fix 1 — visibility:** a vivid `⚠ SYNC INPUT ×` pane pill (fixed theme-independent
  `Slate.Status.syncInput` amber, the `SecureInputPill` rationale) on EVERY pane of an armed tab,
  with `×` → `disarmSyncInput(for:)` (disarms the whole tab); plus an amber grouped-panes glyph
  on the sidebar row (`SlateTabRow.syncInput`, the `readOnly` lock idiom). Both gate on
  `syncInputArmed(for:)`, which reads the observable `syncInputTabs` — arming from the chord,
  the palette, or any sibling's `×` re-renders all surfaces live. The pill is deliberately NOT
  hidden under read-only/vi mode: the mode leaks INTO the pane regardless of its own input gate.
- ✅ **Fix 2 — keyboard-only mirror (`SyncInputByteFilter`):** the fan tap rides
  `TerminalViewModel.sendInput`, which carries MORE than keystrokes — the terminal's own query
  replies (CPR/DA/DSR/XTWINOPS/DECRPM/kitty-flags) and mouse/focus reports flow through the same
  funnel. Those are answers to questions only the SOURCE pane's shell asked; mirrored into a
  sibling they type garbage a later mirrored `↩` executes (observed). Both fans
  (`fanSyncInput` + `fanBroadcastInput`) now strip reply/report sequences from the mirrored copy;
  keystrokes, SS3/CSI keys, kitty `CSI u`, and bracketed paste survive byte-exact. Accepted gap:
  modified F3 shares the CPR byte shape and is dropped from the mirror only. Truncated trailing
  sequences pass through verbatim (input arrives one whole event per chunk).
- ✅ **Follow-up — HOW it armed "by itself": the prefix implied-⌘ fold.** The user never pressed
  ⌘⇧I. `PrefixStateMachine`'s tmux-faithful fold makes any workspace chord reachable from two bare
  terminal keystrokes: `⌃B` (the default prefix — also readline back-char and vi page-up) arms and
  is swallowed, and the next bare key within the 1 s timeout fires its ⌘-folded binding with ⇧/⌥
  carried through — `⌃B, ⇧i` → ⌘⇧I = sync input, silently (the armed chip lights for ≤1 s; nothing
  names the fired action). Fix: `WorkspaceKeyDispatcher.onPrefixActionFired` — every PREFIX-resolved
  action (bound follow-up or fold) now pushes a toast naming the action (registry title, same-id
  replace). A DIRECT single chord deliberately does NOT toast. Pinned by `PrefixActionToastTests`,
  including a proof that `⌃B` + `⇧i` really arms `syncInputTabs`.

## Prefix mode is REMOVED — the ⌘ plane is the only workspace-chord surface (2026-07-22)

- 🔁 **RE-SCOPE (user-directed, supersedes WS-B B2 and every prefix follow-up above): the tmux-style
  multi-key prefix (`⌃B` then a key) is deleted outright — not default-off, not opt-in.** The sync-input
  leak post-mortem settled the design question. A native client already has the partition tmux lacks:
  the PTY never sees ⌘-chords, so ⌘ is a collision-free chrome plane, while a prefix (a) claims a live
  PTY key (`⌃B` = readline back-char / vi page-up / Claude Code background / nested tmux), (b) swallows
  the follow-up of a mistyped arm — typing loss, and (c) via the implied-⌘ fold turned the ENTIRE chord
  table into two-bare-keystroke sequences, which is how sync input armed itself invisibly. The owner of
  the product never knew the feature existed until it misfired — wrong default, wrong feature.
- ✅ **Deleted:** `PrefixStateMachine` + `PrefixIntent` + `KeySequence` (registry AND persisted shapes),
  the sequence tables/aliases (`sequenceTable`, `resolvedSequenceTable`, `aliasSequences`,
  `WorkspaceBinding.sequence`/`effectiveSequence`, sequence glyphs), `defaultPrefixChord` /
  `resolvedPrefixChord` / `KeybindingPreferences.prefixKey` + `sequenceOverrides`,
  `WorkspaceStore.workspaceKeyPrefix` / `applyWorkspaceKeyPrefix`, `PreferencesStore.onPrefixKeyApply`,
  the Settings ▸ Key Bindings ▸ Workspace Prefix row, the armed-pill chrome
  (`OverlayCoordinator.prefixArmed` / `PrefixArmedPill`), and the `onPrefixActionFired` toast seam
  (shipped hours earlier as visibility triage — eradication supersedes visibility). Schema version
  STAYS 3 (fields removed, none added; a stored `prefixKey`/`sequenceOverrides` blob decodes fine —
  unknown keys are simply not read).
- ✅ **Kept:** `WorkspaceKeyDispatcher`'s NSEvent monitor (single ⌘-chords, `text:`/`csi:`/`esc:`
  literal-byte bindings, `unbind:` passthrough, key-window + overlay-yield gates — all non-prefix
  duties), and `TerminalKeyInterceptor` slimmed to the pure single-chord fallback the libghostty
  surface / iOS substrate consult (dispositions now just forward/swallow). `⌃⇧Space` remains the
  Vi-Mode alias chord; the `prefix,[` alias died with the machine.
- **Result contract:** `⌃B` reaches the PTY untouched again; NO bare key is ever swallowed; every
  workspace action is reachable only via its ⌘/⌥ chord, the palette, or the menu.

## Scroll follows the pointer, not focus (2026-07-22)

- 🔁 **RE-SCOPE (user-directed, supersedes the "only the active pane swallows pointer" scroll rule):
  a scroll lands in the pane UNDER THE CURSOR, focused or not.** The dominant real gesture is
  reading: focus (and typing) stays in the working pane while a second pane's output is scrolled for
  comparison — and that gesture previously did nothing useful (⌥-less scroll on an unfocused pane
  panned the whole canvas, or was dropped where no canvas pan is wired). Native macOS scroll routing
  already delivers `scrollWheel` to the view under the pointer; we now stop re-routing it by focus.
  - Terminal panes scroll their OWN libghostty scrollback (or emit wheel reports in a mouse-mode
    TUI — `mouseMoved` was never focus-gated, so report coordinates are already correct).
  - GUI panes forward the scroll to their remote window; the READ-ONLY gate is unchanged
    (`inputEnabled == false` still falls through to canvas pan, live, never pinned).
  - Scrolling does NOT activate the pane — scroll is reading, not focus intent.
- ✅ **⌥-scroll is the one deliberate canvas-pan route**, now uniform across terminal and GUI panes
  (previously the GUI pane's focused-only escape hatch). Background (non-pane) pan is unchanged.
  `ScrollRoutePinner` still pins the route per gesture — now against mid-gesture ⌥ flips.
- **Stays active-pane-only:** click-to-activate, hover tracking / cursor shape, and pinch-zoom
  (a pinch is a zoom command aimed at the pane you're working in, not a reading gesture).

## Scrollback front-truncation vs alt-screen segments: the cut is REPAIRED in the bytes (2026-07-22)

- ✅ **Problem (the documented ring-cap hole, closed proactively):** both scrollback retainers cut
  their stream from the FRONT at the 64 MiB cap — the in-memory ring (`ReplayBuffer` eviction) and
  the disk journal (`ScrollbackJournal.compact`) — with only newline alignment. Claude Code
  (07-2026) holds ONE `?1049h` alt-screen segment open for its whole run (17 MB+ observed), so a
  long session's cut lands INSIDE it: the surviving stream starts with segment interior and ends it
  with an unpaired `?1049l`. `AltScreenSegmentStripper` rightly treats an unpaired close as a
  defensive reset (apps emit redundant `?1049l` on the main screen — Claude's exit cleanup does),
  so the whole beheaded interior replayed onto the MAIN screen on cold reattach — tens of MiB of
  full-screen churn flooding the client's scrollback. "Drop the prefix to the first unpaired `l`"
  was rejected for exactly the redundant-close reason: it guesses; a guess eats real history.
- ✅ **Fix — `AltScreenCutScanner` + repair AT the cut, state lives IN the bytes.** The evictor
  scans exactly the bytes it drops (net DECSET/DECRST 47/1047/1049 state; OSC/DCS bodies opaque; a
  CSI straddling the cut resolves via a bounded kept-head peek; sequences starting in the kept head
  are never applied) and, when the cut is inside an open segment, PREPENDS the re-opening DECSET —
  same mode that entered — to the surviving head (ring head entry / journal file tail, on disk).
  The stream is then well-formed again: the next eviction's scan starts clean (no carried state,
  survives daemon restarts because the journal repair is in the file), and the replay transform
  pairs the segment like any other — closed → dropped whole, still-open → replayed INTO the alt
  screen where it belongs (the cold-reattach resize-dance jiggle repaints the end state). The
  scanner lives in `SlopDeskTransport` (deliberate "mirror, don't share" exception: ring and
  journal both need it, and transport already owns the newline-align eviction discipline). Ring
  edge: an eviction that EMPTIES the ring mid-segment parks the opener (`pendingAltReopen`) and
  attaches it to the next acked bytes entering the ring. Un-acked entries stay byte-exact (warm
  replay untouched); `messages(after:)` raw primitive untouched.
- 📌 **Accepted residuals:** `SLOPDESK_SCROLLBACK_PERSIST=0` (ring disabled by explicit opt-out)
  does not track cap-0 ack discards — the cold tail can still start mid-segment there (pre-existing
  behaviour; the jiggle repaint covers the visible outcome). A journal already beheaded by a
  pre-fix daemon life scans as main-screen until the bad head compacts away (no-backcompat rule).

## Clipboard sync = two MetadataVerbs on the E4 RPC, host pasteboard is the meeting point (2026-07-22)

- ✅ **Problem:** copy on the client did NOT reach the host pasteboard — Claude Code's Ctrl+V found
  "no image in clipboard", and pasting into a remote-desktop pane needed the manual paste-as-keystrokes
  action (text-only, CGEvents). Host-side copies never reached the client at all.
- ✅ **Transport = verbs `15` setClipboard / `16` readClipboard on the EXISTING E4 metadata RPC** (the
  E10/E13 pattern: new verb bytes, no new wire type, envelope byte-identical → golden zero-diff).
  Host-global like the agent-hooks verbs — routed through whichever pane carries a live channel
  (`firstConnectedMetadataClient`); a desktop-pane-only workspace with zero terminal channels does not
  sync (accepted residual — the workspace is terminal-first). Content kinds: UTF-8 text + PNG (image
  preferred; TIFF transcoded both ways so screenshots and app copies land everywhere, incl. Claude
  Code's `PNGf` read). Per-clip cap 12 MiB under the 16 MiB frame cap.
- ✅ **Pull is a POLL, not a push wire type.** The client's `ClipboardSyncEngine` ticks at 1 Hz (the
  `ClipboardMonitor` pattern) and polls `readClipboard` with the last-seen host `changeCount` — one
  tiny count-only RPC per tick when nothing changed. A host→client push type would have cost a new
  frozen wire type + golden churn for a 1 s latency win on a non-latency path.
- ✅ **Loop safety is DOUBLE-guarded, baseline-first.** Host: remembers the changeCount its last
  client push produced and answers "unchanged" for it (never echoes a push back). Client: remembers
  the last clip pushed OR applied and skips both re-push (its own apply) and re-apply by content
  compare. A ping-pong therefore needs both ends to fail. First pull after (re)connect is a baseline
  probe (`lastSeen = -1` → count-only), so connecting never overwrites the client clipboard with
  stale pre-connection host state; a pull failure resets the baseline.
- ✅ **Skips:** concealed clips (`org.nspasteboard.ConcealedType`, password managers) are never
  pushed; file-copy clips (`public.file-url`) are never synced either way (a path is meaningless on
  the other machine); over-cap clips silently stay local. Push failures stay PENDING and retry every
  tick until a newer local copy replaces them. Under automation the engine does not run (an E2E run
  must not mirror the developer's real pasteboard).
- ✅ **Paste-as-keystrokes (⌥⌘V) stays** — it is the fallback for a read-only-disabled sync future and
  the only path that types into a host field that blocks programmatic paste.

## Remote desktop is a DEDICATED OS WINDOW — remote-window mode is REMOVED (2026-07-22)

> User-directed re-scope: (1) per-window streaming (`.remoteGUI`) is removed outright — full-desktop
> is the only remote-viewing mode; (2) the desktop stream must NEVER be a pane or tab inside the
> workspace window — it always opens as its own OS window, with a setting for the default
> presentation (windowed vs fullscreen, the Parsec model); (3) research-backed UX additions.

- 🔁 **RE-SCOPE (reverses the 2026-07-14 "per-window streaming survives as a SECONDARY path"
  ruling): `PaneKind.remoteGUI` is DELETED.** Gone client-side: `newRemoteWindowTab` /
  `openRemoteWindow` / `streamedWindowPane` / `StreamedWindowRef` / `remoteWindowSpec`, the
  `RemoteWindowPickerModal`/`RemoteWindowPickerView` picker UI, the palette "New Remote Window Tab"
  row, Open Quickly's Host rows (their ONLY action was opening a window pane), and `WindowRebind`
  (CGWindowID-recycling rebind existed solely for persisted `.remoteGUI` panes). A persisted
  `"remoteGUI"` leaf folds to `.terminal` via the established legacy-raw-value decode bridge
  (`claudeCode`/`web`/`chooser` precedent — no-backcompat rule, stale stream identity is dropped).
- ✅ **The WIRE is untouched — window-shaped types go dormant, not deleted.** `hello` (1) stays
  LIVE (the `.systemDialog` pane still streams a host window by id); `resizeAck` (5), `listWindows`/
  `windowList` (7/8), `displayMax` (15), geometry datagrams (§9.5) lose their `.remoteGUI` caller and
  join types 19–21 in the dormant set (codec + golden vectors byte-identical, zero golden churn).
  `HostWindowFeed` + types 16–18 stay KEPT-SHARED for `AppLaunchMonitor`'s layout auto-switch. Host
  window-capture machinery (parking, geometry watcher) stays — systemDialog and any future window
  consumer ride it; deleting it buys nothing the dormant rule doesn't.
- ✅ **The desktop stream lives ONLY in a satellite window — never in the tree.** `.desktop` panes
  are minted DIRECTLY into `Session.detached` (⌥⌘N / palette; reveal-dedupe per display — a second
  ⌥⌘N on the same display raises the existing window; different displays mint siblings). The
  satellite close semantic branches by kind: a desktop satellite's close is a REAL close
  (`closeDetachedPane` — the session ends), never the reattach-fold; reattach affordances
  (`reattachAllPanes`, free-drag-into-tree) skip desktop panes. Launch restore DROPS persisted
  detached desktop panes instead of redocking them (satellites don't restore as windows — v1 rule —
  and a desktop pane must never redock into a tab).
- ✅ **Presentation setting: `desktopWindowPresentation` = windowed (default) | fullscreen** —
  a `SettingsKey` + macOS Settings row. Fullscreen v1 is NATIVE macOS fullscreen (Spaces): most-Mac
  behaviour, zero custom chrome. The known top-edge conflict (pointer at top reveals the LOCAL menu
  bar over the remote one — unsolved across Parsec/Screens/Jump/Apple; Parallels' dwell-delay gate
  on a borderless window is the researched best-in-class) is ACCEPTED for v1 and the dwell-gate
  borderless mode is the documented follow-up.
- ✅ **UX additions v1 (survey-backed, `docs/DECISIONS.md` is the research record):**
  (a) **fullscreen auto-arms immersive system-key capture** — the industry-converged pattern
  (Parsec Immersive / CRD "Send system keys" scoped to fullscreen / Moonlight's capture toggle):
  entering native fullscreen arms the existing `SystemKeyCaptureController` regardless of the
  latched per-target immersive mode; exiting returns to the latched value. The in-session escape
  hatch already exists (the immersive toggle chord) — the Moonlight lesson (capture with no
  in-stream off switch traps the user) is already satisfied.
  (b) **hostd keeps the host display awake while a display session is attached**
  (`IOPMAssertionCreateWithName` / PreventUserIdleDisplaySleep — released when the last display
  session detaches). No surveyed product does this declaratively; it closes the "host slept mid-
  session" failure mode for free.
- ✅ **UX backlog SHIPPED (2026-07-22, "làm hết tất cả những thứ hay đáng học hỏi"):**
  - **In-window display switcher** — already existed (the footer `GuiDisplaySwitcherMenu` +
    `RemoteWindowModel.switchDisplay(to:)` over the `listDisplays` 22/23 discovery). Verified in
    place; no new work.
  - **Parsec-grade stats HUD** — the in-pane readout gained a RTT / ENC / DEC latency row. New wire
    type 27 `hostStats` (host→client, ~2 Hz over the client's report clock) carries the host's
    smoothed RTT (only the host can compute it — every client-report field is relative, §9.8) + its
    now-always-measured encode-wall EWMA; the client times its own decode-wall EWMA around the VT
    submit. Zeros map to a dash (no fake 0.0). Additive golden splice.
  - **Dwell-gated borderless fullscreen** — a third `desktopWindow.presentation` (`borderless`): a
    `.borderless` cover of the current Space whose local menu bar/Dock hard-hide behind a
    `BorderlessDwellGate` (0.5 s dwell, 2 pt arm, 36 pt conceal hysteresis) — a bare top-edge touch
    reaches the REMOTE menu bar, a held one reveals the LOCAL. The Parallels answer to the top-edge
    conflict. The standard fullscreen verb (⌃⌘F) toggles it; engaging auto-arms immersive capture.
  - **Host-display privacy blank** — new wire type 28 `privacyMode` (client→host, display sessions
    only). `HostPrivacyBlank` blacks the streamed display with a zero `CGDisplayGammaTable` (client
    still sees the desktop; a bystander sees black). The RustDesk gamma technique ships live; the
    local-input `CGEventTap` swallow is behind a host seam (a HW-verified follow-up — a wrong tap
    would block the remote operator's injected input too). Desktop-pane footer shield toggle.
- 📌 **Deliberately NOT done** (rejected, not deferred): match-window dynamic resolution — the
  research verdict stands that it is the WRONG default for a real physical host display (scale-to-fit
  letterbox stays).
- ✅ **PATH 4 — drag-and-drop file transfer over a DEDICATED reliable channel (2026-07-23, "tạo 1
  connection mới, đừng dùng chung vào terminal tránh gây lỗi"):** dropping a file onto the desktop
  window uploads it to the host. Per the user's explicit constraint this rides its **own** TCP
  listener — NOT the terminal mux (a bulk file body sharing the PTY's data channel would stall
  keystrokes/resizes and risk framing errors), NOT the lossy UDP video path (FEC recovers *frames*,
  not files). A genuinely 4th path, modeled on the **inspector** precedent (the simplest existing
  self-contained TCP server), NOT the terminal's CONTROL/DATA mux dance.
  - **New module `SlopDeskFileTransfer`** (Foundation + Network leaf, shares nothing with the other
    three paths per the "do not merge" rule). Its own `[UInt32 BE length][UInt8 type][body]` frame
    shape (16 MiB cap) with a dedicated `FileTransferFrameDecoder` (mirrors `MuxFrameDecoder`'s
    streaming-splitter/lazy-compaction/poison-on-fault design — NOT a reuse of it). Version-pinned
    `hello`/`helloAck` (v1, no negotiation). Message table → `docs/20-wire-protocol.md §10`. This
    path is **outside** the golden corpus (golden = the PATH-2 video control codec only).
  - **Pure, headless-tested core:** `FileReceiveLogic` (offer→open→chunk→finish FSM, validate-then
    -drop: rejects a chunk-before-offer, a byte overrun past the offered size, an over-cap total, a
    bad name) + `FileNameSanitizer` (**path-traversal guard** — last component only, rejects
    `..`/absolute/empty, the untrusted-name attack an upload endpoint invites) + `FileTransferCodec`
    round-trip + collision-avoiding `DiskFileDropSink` (`name (1).ext`). The `NWListener` server +
    `NWConnection` client are compiled-not-tested (loopback `serve(channel:)` + fake-sink seam prove
    the logic, per hang-safety — no live socket in XCTest).
  - **Direction = client→host upload only** (the "into the desktop" gesture); host→client download is
    a future add. **Drop dir default `~/Downloads`** (the received-files convention; env
    `SLOPDESK_FILE_DROP_DIR`). Server gated `SLOPDESK_FILE_TRANSFER` (default-ON), stood up in
    `slopdesk-hostd` after the terminal + inspector servers on `terminalPort &+ 2`, **non-fatal** on
    bind failure. Client derives `ConnectionTarget.filePort = port &+ 2` (computed, mirrors the
    inspector's `+1` — no new persisted/golden field).
  - **UI:** the desktop pane registers an AppKit dragging destination for real file payloads (a file
    *drop* uploads bytes; the existing `PaneDropReceiver` path-inject stays for terminal panes) with
    a progress overlay + completion toast; `FileTransferModel` (pure `@Observable` in WorkspaceCore)
    holds active-upload progress behind a `FileUploading` seam the app fills with the real client.
- ✅ **2026-07-23 — Git status is PROJECT-scoped, rendered on the sidebar SECTION HEADER; the grouping key is bullet-proofed; freshness is project-scheduled + event-driven (wire 35).** Three decisions in one re-scope (user-directed):
  - **Grouping = git toplevel even from a subdir, ALWAYS.** The host resolver already walked up to the
    toplevel; the fix closes the windows where the raw subdir cwd leaked through as the section key:
    (a) new split/tab specs SEED the parent's host-pushed `projectKey` alongside the inherited cwd
    (subtree-coverage-guarded — never seeds across a policy-resolved foreign dir or a stale key);
    (b) the host seeds cwd+key truths AT SPAWN from the server-provided spawn cwd — a pane whose
    shell never emits OSC-133/OSC-7 (raw command, shim off) still resolves; (c) the resolver walks
    the `realpath`-canonicalized cwd, so logical OSC-7 paths and physical `proc_pidinfo` paths land
    on ONE key (a symlinked checkout no longer splits into two sections — or resolves the SYMLINK
    dir as its own bogus toplevel). Non-repo dirs keep grouping by plain cwd (unchanged, intended).
  - **One repo = one section = ONE git line, on the header.** `projectGitSummary` (keyed by the
    normalized section key — the `gitStatus` reply's `repoRoot`) replaces the per-pane mirror + the
    sibling fan-out; the header renders branch + non-zero oh-my-zsh sigils in the INSTRUMENT voice
    (`ProjectGitStatusLine` — branch recedes to the header gray, per-token status colours, branch
    pre-truncates so counts never do, conflict `=N` escalates to the header's ONE background
    treatment: a static err-tinted pill, hard cut per L3). The pane row's line 2 becomes the cwd
    RELATIVE to the project root, shown ONLY when the pane strayed from it (at-root rows collapse to
    single-line height); "Refresh Git Status" moved from the row menu to the header menu. iOS keeps
    plain system section headers (macOS-first refinement).
  - **Inactive projects stay fresh, cheaply.** The ~3s snapshot edge is re-scoped from
    "active PANE only" to per-PROJECT windows (active project 15s, background 60s) with a
    project-keyed in-flight de-dupe — N same-repo panes reconnecting/polling collapse to ONE RPC
    (`git status --porcelain` output is root-relative, so any pane answers for the project), cost
    bounded at O(projects)/window. On top, **wire type 35 `projectGitStatus`** (host → client,
    control): a per-repo FSEvents watcher (`RepoStatusWatcher`, refcounted across panes via the
    type-34 latch edges, 0.75s debounce, dirty-guarded, `SLOPDESK_GIT_WATCH` default-ON gate,
    probe-skipped when no client is attached) pushes the HOST-folded summary (shared
    `GitStatusPayload.foldedCounts` — the file list never rides the push) to every session
    sectioned under the repo; the client backs its poll off to 300s while pushes stay fresh, so an
    old host degrades gracefully to poll-only. The status probe gained `--no-optional-locks` (a
    read-only cadence probe must never contend the user's own git on `index.lock`). → [20 §type 35],
    `RepoStatusWatcher.swift`, `ProjectGitStatusLine.swift`, `WorkspaceStore.swift` (§Section git line)
- ✅ **2026-07-23 — Satellite windows take POINTER interaction while NOT key ("background interaction", user-directed).**
  The dedicated remote-desktop window (and any ⌥⌘P pop-out) went inert the moment another window had
  focus: hover/cursor tracking was `.activeInKeyWindow`-gated, AppKit consumed the first click purely
  to activate the window, and every pointer forward was gated on `isActive` (== window key for a
  satellite). Now a satellite surface forwards hover, clicks, drags and scroll to the host while the
  window stays INACTIVE — and a click deliberately does NOT activate it (`acceptsFirstMouse` +
  `shouldDelayWindowOrdering` + `preventWindowOrdering`, the drag-from-a-background-window mechanism):
  the pointer operates the remote desktop while the KEYBOARD stays wherever the user is typing — the
  scroll-follows-the-pointer philosophy extended to the whole satellite window. Focusing for typing
  stays explicit (title-bar click / ⌥⌘N / ⌘\`). Keyboard while not key is untouched (macOS routes keys
  to the key window; the immersive CGEvent tap already self-suspends on resign-key; the borderless
  dwell gate keeps its own key guard). Canvas panes keep click-to-activate unchanged — the flag rides
  the `RemotePaneContext` seam and `GuiLeafView` threads it ONLY for a detached pane. The pure gate
  decisions are `BackgroundPointerPolicy` (headless-pinned; the video view itself is never
  instantiated in tests). Setting: "Background Interaction" (Window section,
  `satelliteWindow.backgroundPointer`, default ON). Client-only — no wire change, no host redeploy.
- ✅ **2026-07-23 — System-dialog panes REMOVED; no video surface lives in the workspace window (user-directed).**
  The auto-spawned `.systemDialog` pane (the "show system popups in their own pane" feature: client
  polls `listSystemDialogs` → mints an ephemeral in-tree video pane per host SecurityAgent prompt) is
  retired. It was the LAST video surface inside the workspace window; with it gone, the remote desktop
  is fully separated: the ONLY video surface is the dedicated desktop OS window (detached `.desktop`
  pane, ⌥⌘N), and nothing video-shaped can enter the tree — the `reattachPane` family already refuses
  `.desktop` ("the desktop never joins a tab"), launch restore already drops every persisted `.desktop`
  leaf, and the retained-but-dead canvas fallback no longer mints a desktop pane. `PaneKind.systemDialog`
  is gone (persisted `"systemDialog"` decodes to `.terminal` via the legacy bridge, same discipline as
  `"remoteGUI"`); `SystemDialogMonitor`, the `SystemDialogDiscovery` seam, the
  `features.systemDialogPanes` setting, `SLOPDESK_SYSTEM_DIALOG_PANES`, the host's answer path and
  `scripts/check-system-dialog.sh` are deleted. **Wire stays DORMANT, golden zero-diff** (the
  remote-window precedent): `listSystemDialogs` (11) / `systemDialogList` (12) + `SystemDialogSummary`
  keep their codec + vectors, and the pure `SystemDialogDetector` classifier stays (its classify/detect
  golden vectors are pinned) — only the runtime plumbing is gone. The window-shaped `VideoEndpoint`
  survives as the AUTOMATION seam only: `check-video.sh`'s window-targeted autoconnect now boots a
  DETACHED `.desktop` pane (window endpoint, `RemoteWindowModel` window binding) instead of an in-tree
  pane 0, so the E2E runtime gate is preserved without re-admitting video into the tree.
- ✅ **2026-07-23 — Tab row = supervision instrument: ONE-SHAPE StatusRing + readout line + telemetry column + session-scoped height (user-directed).**
  With project identity + git on the SECTION HEADER, the per-tab dir/git lines were redundant; the row
  is redesigned around supervising many agents (research pass over Warp's agent tabs + T3 Code's
  indicator system — the latter is open source, `pingdotgg/t3code`, and its two load-bearing recipes
  are adopted: STEPPED motion (`steps(N)`-style discrete frames, never an eased breathing pulse) and
  a hard colour budget (colour only for act-now / in-motion / broken / unread-done; the resting state
  is the UNLABELED state)).
  - **One shape, many readings (`StatusRing`).** The badge vocabulary previously swapped silhouettes
    per state (dot+orbit ring / bare dots / SF-symbols) — a state edge read as an icon swap ("giống
    layout shift" even though the 16pt box never moved). Now every lifecycle state is a READING of the
    same Ø12 ring: working = dashed 8-segment ring, lead segment ticking one slot per 0.2s beat (a
    mechanical escapement, agent-only motion); awaiting = amber ring + centre dot + ONE stepped halo
    pulse per 2s (front-loaded, 8 discrete frames); done/unread = green ring + check (the `.completed`
    flash and `.finished` unread marker render identically — the enum split survives for the freshness
    machinery); error = red ring + cross; OSC 9;4 progress = muted ring + micro-dot, STATIC; sudo/
    caffeinate = glyph inside the muted ring. Only the plain busy shell stays a sub-ring 6pt micro-dot
    (concentric: an agent taking over reads as the dot growing a ring). Awaiting moved red→AMBER
    (act-now); red is reserved for broken. `SlateOrbitDot`/`SlateCometArc`/`SlatePingDot` deleted.
  - **The row grid: [2pt attention tick][content][4ch telemetry][16pt badge rail].** The tick
    (amber = a question waits, red = broken; hard cut, motionless, never fades under hover) gives a
    dedicated left-edge who-needs-me scan channel; the badge moved from its two per-line positions to
    ONE full-height vertically-centred rail slot (constant x AND constant anchor — a continuous scan
    column); the telemetry column (instrument small, right-aligned, `Slate.Metric.telemetryCol`) shows
    at most ONE value by badge precedence: blocked-age (AMBER — the sole coloured number, an ignored
    question must not look fresh), working turn-elapsed (from the `paneAttentionAt` `.working`-edge
    stamp; ≥10m escalates one luminance step — the stuck-agent answer), unread-age, command elapsed /
    determinate OSC 9;4 percent (`progressPercentLabel`'s first call site), or a non-agent error's
    bare exit code. Ages reveal at 60s; the duration grammar is clamped ≤4ch (`42s/12m/1h04/>9h`,
    `RailRowTelemetry`); the per-row clock is a `TimelineView` mounted ONLY while a value can show.
  - **Line 2 = the agent READOUT, by precedence (`RailRowReadout`):** blocked question > inspector
    todo scent (`3/5 · Editing …`, promoted from the tooltip; counter prefix leads so `.tail` can't
    eat it) > wire-27 last assistant line while working (~2s min-dwell against mid-turn churn) > the
    agent's FINAL line while done-unseen (the label already crossed the wire and was discarded) >
    `exit N · command` from the block model on error > the strayed relative cwd (demoted to the
    lowest rung, NOT deleted) > reserved blank. The process label became a COMMANDS-ONLY voice
    (suppressed on agent rows — the ring already says agent). Tooltip = full cwd + untruncated prose
    readout + `command · duration · exit N`.
  - **Height changes only at SESSION boundaries.** An agent row (any `ClaudeStatus` verdict, or a
    known agent CLI in the foreground — `RailRowsBuilder.isAgentSession`) HOLDS the 44pt two-line
    shell for the whole session (blank line 2 reserved when idle), with a 10s sticky decay on exit —
    so a question/done/error edge swaps text inside a fixed shell and NEVER moves layout (previously a
    subtitle-less row grew 32→44 the moment a question arrived). Non-agent rows keep 32pt (strayed-cwd
    rows keep their structural 44pt).
  - **Section header gains the act-now tally** (`●N`, amber, reserved slot, absent at zero): how many
    panes in the project are blocked/broken, counted through the SAME gated badge pipeline the rows
    render — "which PROJECT needs me" at a glance.
  Client-only; no wire change (every element binds to signals already crossing: wire 26/27/32, the
  attention/completion/command stamps, `TerminalBlockModel`, `PendingToolSummary.scent`). iOS keeps
  its system rows (ring badge inherited; readout/telemetry/tally deferred, macOS-first).

## Tab-row v2: Linear fill-fraction glyphs in a LEADING column, uniform two-line rows (2026-07-23)

- **Decision:** Rebuild the sidebar tab row around ONE leading status-glyph column speaking the
  Linear fill-fraction vocabulary, and make EVERY row the same two-line shape. Supersedes the
  same-day READOUT+RAIL trailing-rail design (its resolvers survive; its layout and its animated
  ring do not).
- **Why:** On hardware the trailing rail read as cramped and the escapement ring as generic
  "AI slop". Root causes, confirmed against the T3 Code source and the icon-family geometry it
  leans on: (1) a lead segment advancing around a circle is still a SPINNER — the crafted systems
  (T3, Linear, Octicons) never rotate anything; their only motion is a stepped opacity duty cycle
  (`steps(n)` ramps between two plateaus — discrete frames, e-ink cadence, on an already-simple
  shape); (2) our dash gaps (~6.5° vs ~38° dashes) collapsed into a "cracked circle" at Ø12 — the
  icon-family proportion is dash:gap 1:1 (8 × 22.5°); (3) semantics carried by 12pt micro-geometry
  plus a bare 4-char number is illegible — the crafted systems encode state as HOW MUCH of one
  fixed circle is drawn/filled (the `◌ ○ ◔ ◉ ●` terminal-glyph ladder), with terminal states
  earning the only solid fill; (4) a 46pt rail reserved on BOTH lines of a 220pt sidebar squeezed
  the title and left the number context-free.
- **The vocabulary (`StatusRing`, one Ø12 circle, 16pt box):** working = dashed `◌` (8 dashes, 1:1,
  one centred at 12 o'clock), whole-glyph flicker 1.0↔0.75 on T3's duty cycle (3.4s, hard 1/10
  steps, wall-clock phase from a fixed epoch — all working rings tick in unison, remounts land
  mid-cycle); awaiting = amber ring + centre dot `◉`, STATIC (halo deleted); done/error = the
  SOLID disc with a knocked-out ✓/✕ (ground-tone cutout); commandBusy = hollow muted `○`;
  commandRunning = muted ring + a centre pie wedge swept to the REAL OSC 9;4 fraction (r 3.5 —
  Linear's inner-fill proportion; indeterminate = bare ring); sudo/caffeinate glyphs unchanged.
  The only motion in the sidebar is the working flicker.
- **The layout:** `[16pt glyph column][title + readout][trailing telemetry text]`. The glyph column
  leads (a vertical scan line of readings, lazygit-style) and anchors on line 1; the attention
  tick is deleted (an amber/red glyph at a constant leading x IS the tick). The trailing rail and
  its reserved telemetry column are deleted — the telemetry value is right-aligned TEXT in the
  title line's timestamp slot (the T3 idiom), and line 2 runs the row's full width (minus the
  hover-`×` reserve). EVERY row is two-line (`reserveSubtitle` always): the height ladder and the
  session-scoped rung + 10s sticky decay are deleted outright — no state edge can EVER move
  layout because there is nothing left to move. Line 2 gains a RUNNING-COMMAND rung (open block's
  command text, fallback process label) between error and strayed-cwd; the line-1 process label is
  gone. A RESTING row (no badge, not active, not hovered) RECEDES to the secondary title tone —
  the T3 `shouldRecede`: the quiet state is dimness, colour + full ink are earned by live state.
- Client-only; no wire change; golden untouched. The readout/telemetry resolvers, hue budget,
  header tally and iOS system rows carry over unchanged.

### v2.1 — HW-review follow-ups (2026-07-23)

First hardware look at v2 surfaced three faults; all fixed the same day:

- **Glyph "slightly off" line 1** — the leading slot was centred over the whole two-line row and
  lifted by a hand-tuned `-7pt` offset. Replaced with a real custom vertical alignment
  (`VerticalAlignment.slateLineOne`): the line-1 HStack exposes its own centre as the guide and the
  shell's outer HStack aligns the accessory to it, so the glyph tracks the laid-out title line
  exactly and can never drift with font/metric changes.
- **Line 1 repeated the section header** — under By-Project grouping, a pane AT its project root
  titled itself with the same folder name the section header already carries (every at-root row in
  a section read identically). New `rowTitle` rung: at the project root the row titles by its
  foreground PROGRAM (`claude` / `vim` / `make` — the tmux idiom: header says WHERE, line 1 says
  WHO); an idle shell yields the kind-generic "Terminal". Strayed panes keep the folder name; an
  explicit rename still wins; the titlebar/window-title call sites omit the key and keep folder
  names. Consequences wired through: the worktree-collision disambiguation moved UP to the section
  header (`headerDisambiguated` — `feature-a/myapp` vs `feature-b/myapp` as HEADERS now), and
  `RailStructureKey.titledByProcess` is project-key-aware so an at-root pane's process change is
  structural (retitles) while a strayed pane's stays a volatile cache hit.
- **Section header layout** — the header hung into the gutter (8pt inset vs the rows' 12pt content
  inset) and the act-now tally kept a fixed 22pt reserve that read as a ragged hole against the
  right edge whenever it was empty. The header now sits at the rows' own content inset (flush over
  the glyph column), the tally renders only when non-zero, and each section gains breathing room
  above its header. New opt-in snapshot render (`sidebar-section.png`) locks header↔row alignment
  visually.

### v3 — flush-left rows, ASCII status glyphs, two-line header (2026-07-23)

Second hardware review: the leading glyph column — even perfectly aligned — indents every title off
the section header's left edge, and the drawn status rings still read as ornament. Direction: return
to the pre-v2 flush-left row anatomy, keep the uniform two-line shape, and speak status as TEXT.

- **The leading glyph column is GONE.** Rows are flush-left again (the old `SlateListRow` no-leading
  shell); status moved into the line-1 TRAILING cluster next to the telemetry number, where `✻ 4m`
  reads like an AI CLI's status line. `StatusRing`/`TabBadgeView` live on for the titlebar tab menu
  and iOS rows; the sidebar speaks `AsciiStatusBadge`.
- **Status is a text glyph in the instrument voice** (`AsciiStatusBadge`): agent working = the
  AI-CLI pulse `· ✢ ✳ ✶ ✻ ✽` (frame-stepped on the wall clock from a fixed epoch — hard swaps, rows
  in unison, re-render can't reset phase); command running/busy = the braille dot-walker, muted;
  static `?` amber (blocked), `✗` red, `✓` green/muted, `#` (sudo — the root prompt's sigil), `∞`
  (caffeinate). A fixed 13pt slot pins the cluster while frames/states swap. The determinate OSC
  9;4 pie is retired — the telemetry slot already carries the exact percent.
- **Line 2 is ALWAYS filled, never a duplicate.** New floor rungs under the readout ladder: the
  strayed cwd, then the LAST COMPLETED command line (`make check · 12s · ✓`), then the shell
  identity (`zsh` — suppressed when it would repeat the title, e.g. an at-root row titled
  `claude`), then the tab's `⌘N` shortcut hint. A resting row now reads as two useful lines instead
  of title + reserved blank.
- **The section header is TWO lines**: the caps project name + act-now `●N` tally over the
  project's git line (branch + dirt sigils); a non-repo project shows WHERE it lives instead (the
  `~`-abbreviated parent path). Both lines sit at the rows' own content inset, so the header and
  every title share one left edge — the misalignment complaint dies structurally.

### v3.1 — the de-dingbat pass: `!<code>`, `?N !N` tally, one-tone git, section rule (2026-07-23)

Hardware review of v3: the remaining round/nerd-font symbols (`✗ ✓ ●N`, the git arrows, the conflict
pill) still read as generated chrome. The pass replaces the residual symbol vocabulary with ASCII
text and spends the freed contrast on ONE animation idiom:

- **Error badge = `!<exit code>`** (`!137`, err-red) — the shell's own bang fused with the number a
  glance actually wants; a code-less error (agent / live OSC 9;4;2) reads the bare `!`. The
  telemetry slot drops its exit-code branch (the badge carries the number) and always answers "how
  long has it sat broken"; the line-2 error rung drops to the failing COMMAND alone — the pair
  `!137 12m` / `npm test` never repeats a digit. `✓ → ok` (green unread / muted decayed): a word in
  the instrument voice, not a dingbat.
- **Header tally speaks the rows' own dialect**: `●N` → `?N` (blocked questions, amber) + `!N`
  (failures, err) — the header total and the row badges are one vocabulary. The cluster BLINKS like
  a terminal cursor (soft opacity dip, hard swap, phase-locked to the shared wall-clock epoch so
  every project's tally dips together) — attention data is the one place the header earns motion.
- **Git line goes `__git_ps1` ASCII + one tone**: `↑↓` → `>`/`<`; every count reads the same
  secondary grey (the 10pt token rainbow read as noise); colour is rationed to the conflict `=N`
  (err-red text — the pill's background plate is gone, the one state that blocks work keeps the one
  hue).
- **The header earns its structure from a RULE, not a bead**: a hairline fills the width between
  the caps name and the tally (the lazygit `── title ──` idiom) — the section reads as drawn
  TUI chrome, and the tally hangs off the rule's right end.

### v3.2 — the readout earns line 2; the header goes still (2026-07-23)

Hardware review of v3.1: the section rule read as ornament, the tally blink as irritation, and the
row's "always-filled" second line as filler — a strayed-cwd echo of the title's own basename, a full
command under a command title, `claude` under an agent row. The verdict: line 2 must carry
information the row doesn't already state, or not exist.

- **The second line is EARNED, not reserved**: `RailRowReadout` keeps only the live rungs —
  question / todo scent / working label / final line / failing command / running command — and the
  structural fillers (strayed cwd, last-command history, shell identity, `⌘N` hint) are gone; a
  settled row COLLAPSES to the compact single-line shell (`SlateTabRow` no longer reserves the tall
  shape). A second line now always means "something is happening here"; history and the full cwd
  stay in the hover tooltip. Height changes only on real state edges.
- **The title-echo gate**: command-shaped rungs are dropped when they would only repeat the title
  (equal or word-bounded extension, `npm` ↔ `npm test`) — the case where a shell titles the pane by
  its own command. Prose rungs are exempt (a question quoting the title is still news).
- **Header: no rule, no blink.** The hairline between name and tally is deleted (the caps name +
  right-aligned tally is the whole structure) and the `?N !N` tally is static — its colour against
  the header grey is the signal; a permanent blink taxed attention instead of directing it.

### v3.3 — one line, one face: the rail reads like terminal text (2026-07-23)

Hardware review of v3.2: rows mixing one and two lines read as visual jitter, and the rail still
didn't look terminal-native — it wanted the terminal pane's own monospace face.

- **Every row is ONE fixed-height line.** `SlateListRow` loses the whole subtitle/reserve machinery
  (`heightRowTall` deleted from the ladder); the READOUT moves INLINE after the title in the dimmed
  secondary tone, truncating `.tail` before the title does (the tooltip keeps the whole line). State
  changes swap text, never row geometry — the list's rhythm is a constant beat, tmux-dense.
- **The rail speaks the instrument face end-to-end**: row titles, the inline readout, the rename
  field, the search field, the empty label and the drop slot join the header/git/telemetry lines in
  the mono voice — the sidebar reads like terminal text, in the same family libghostty embeds as the
  terminal default (JetBrains Mono).
- **The instrument voice can no longer silently fall back to proportional SF**: `Font.custom` with a
  missing family degrades to the plain system face, which on a machine without JetBrains Mono
  installed erased the entire mono register (the app does not bundle the font — the terminal's copy
  is embedded inside libghostty, invisible to AppKit). `Slate.Typeface.instrument` now checks the
  family once and falls back to SF Mono (`design: .monospaced`) — always a real mono.

### v4 — the otty reset: the sidebar returns to the source (2026-07-24)

Verdict after the v2→v3.3 saga: every visual added to the rail (git line, telemetry column, act-now
tally, inline readout, whole-rail mono) moved it FURTHER from the otty elegance the whole design
system was reverse-engineered from. The sidebar resets to otty's `TabsPanelRowView` 1:1
(`otty-reversed/Sources/UI/OttyReplica.swift` measurements + `docs/otty-clone/screenshots/`), with
ONE deliberate step past otty kept: always-on By-Project grouping.

- **The row is the otty row**: 34pt (`heightTabRow`, off the 4pt ladder — the replica measurement
  wins), 14pt inset, radius 7, title in the SYSTEM face 13 (medium when active, primary ink always —
  the T3 recede is gone), one trailing 28×18 slot carrying the resting SHELL LABEL (`zsh`, muted 11)
  or the status badge, swapping to the close `×` under hover. Active = raised card + hairline + the
  measured 4% cast shadow (returns with the reset; MERIDIAN L5's no-shadow rule yields to the
  measurement). `SlateTabRow` no longer rides `SlateListRow` — it IS the otty row, standalone.
- **Badges are the otty icon set** (`tab-badge.png`): ONE muted rays spinner for every busy tier
  (otty does not colour-grade motion), orange raised hand = awaiting input, red triangle = error,
  green check = task done, small green dot = unseen finish, `# ∞` stay small muted text.
  `AsciiStatusBadge` (text-glyph dialect) and `StatusRing` (one-shape fill-fraction vocabulary) are
  deleted; `TabBadgeView` is the one badge, shared by the sidebar, the title menu and iOS.
- **Deleted from the rendered rail**: the inline readout, the telemetry column (`RailRowTelemetry`
  gone), the header git line (`ProjectGitStatusLine` gone), the `?N !N` tally, the macOS search
  field (otty's sidebar is bare rows — Open Quickly is the finder; iOS keeps system `.searchable`),
  and the whole-rail mono register (the sidebar speaks the system face again; `instrument` remains
  for genuinely technical text elsewhere). The RICHNESS did not die — it moved where otty keeps it:
  the row tooltip (cwd + live agent line via `RailRowReadout` + last command) and the header tooltip
  (full path + git line), plus the context menus.
- **The project header speaks otty's own header grammar**: ONE caps line, system 11 semibold,
  `tracking(0.6)` (`capsTracking` — the measured "TABS" register), on the panel's 16pt label column,
  separated by AIR (16pt top), no rule, no counts. Hierarchy by luminance: "TABS" (panel chrome)
  keeps the lightest header grey; project names sit one ink step darker (`Text.secondary`) as
  content taxonomy — exactly how otty ranks the Details panel's "STAGED"/"CHANGES" against rows.

### v4.1 — the LIVE otty port: measured off the running app (2026-07-24)

The v4 reset was built from the historical replica + screenshots; the user then opened the CURRENT
otty (which has grown native By-Project grouping) and asked for a 1:1 port of what is actually on
screen. Every number below is pixel-sampled off the live window at 1× (`otty-cli tab new --cwd …`
probe tabs at controlled depths nailed the header dialect; `tab list --json` exposed the semantics).

- **The row re-measures**: height 34 → **36**, title inset 14 → **10** (title ink starts x18 against
  the card at x8), and the resting title drops to the SECONDARY ink — only the active card's title
  reads primary (+ medium). List inset 8, spacing 2, radius 7, card + hairline + shadow all held.
- **The group header is otty's real anatomy, not a caps line**: `chevron.down` (x≈10, muted) +
  dim `folder.fill` (x≈27) + the project PATH in the plain system face 11 at x≈46 — lowercase,
  trailing `/`, `~`-abbreviated (any `/Users/<name>` prefix — the key is a HOST path), and
  middle-elided past ~32 chars keeping FIRST + `…` + as many TRAILING components as fit
  (`/Volumes/…/oss/slop-desk/`; the live app renders its own quirky component order — ours keeps
  original order, same grammar). Header band = 24pt + the 2pt list gaps = the measured 28pt; the
  air IS the group separator (no rule, no counts, no caps). Tapping collapses the group
  (chevron.right; session-scoped `@State`). The v4 caps-line header is superseded.
- **The `✳` agent marker is title text**: `tab list --json` showed otty's agent integration
  literally prefixes the title string (`"✳ Claude Code"`). `SlateTabRow` grows `agentMarker:`
  (rendered `✳\u{FE0E}` — VS15 pins text presentation) driven by `isAgentSession`; the rename field
  still seeds from the bare title.
- **The TABS row gets otty's trailing panel-menu icon** (`line.3.horizontal.decrease`, header ink):
  theirs opens GROUP/ORDER/DIVIDER modes; ours is always-grouped-by-project, so the menu carries
  only honest actions (Collapse/Expand All Groups, Refresh Git Status).
- Badge COLOURS stay the v4 mapping (`tab-badge.png` — the live capture's grey hand is just the
  inactive-window render). The trailing pane-count otty shows does not map: our rows are per-PANE,
  not per-tab.

### v4.2 — the daily-driver header: name + live git line, animated collapse (2026-07-24)

Three adoptions after driving v4.1, one measured addition. The user's read: the full (elided) path
in every group header is noise once you know your projects — and the collapse snap felt raw.

- **The header names the FOLDER, not the path**: the title is `section.header` verbatim — the
  basename `TabOrderingEngine.projectSectionHeader` already derives (worktree collisions already
  parent-qualified by `headerDisambiguated`). `displayPath` and its elision dialect are deleted;
  the full path lives where the richness lives, the hover tooltip.
- **The git line moves INTO the header**: the muted trailing slot (right inset 10 — the rows'
  trailing-label x) carries `gitLine` (`main >2 !3`, header ink, footnote) while the group is open.
  Freshness is the existing project-scoped FSEvents push (wire 35). The name wins the truncation
  fight (`layoutPriority`), a long branch tail-truncates.
- **Collapsed shows the hidden-row COUNT** — measured off the live app: collapsing a group in otty
  swaps its trailing slot to the muted tab count at the row-label x. `trailingLabel(collapsed:count:summary:)`
  is the pinned pure swap (count while shut, git while open).
- **Collapse ANIMATES — a deliberate otty deviation**: a 60fps recording of the live app
  (background `screencapture -v` + a driven chevron click) proves otty snaps collapse in ONE frame.
  The user called the snap crude, so ours glides: every `collapsedSections` mutation (header tap +
  the TABS-menu Collapse/Expand All) wraps `Slate.Anim.standard`, and the disclosure is ONE
  `chevron.right` rotating 0°↔90° (not a symbol swap) so the glyph turns with the rows.
- The chevron drops semibold → **medium**: the live glyph is a 1px stroke; semibold at 10pt read a
  step chunkier than the reference.

### v4.3 — the header goes two-line (2026-07-24)

Driving v4.2, the user found one line too little area: the folder name and the git line share a
24pt row, so either can starve the other. The header becomes TWO lines while a git line exists:

- **Line 1 = the name, line 2 = the git line** — the git line moves from the trailing slot to a
  full-width small-face line under the name (header ink, indented to the name's x46), so branch +
  dirt and the name each get a whole line. `trailingLabel` splits into the pinned pair
  `detailLine(collapsed:summary:)` (second line while open) + `trailingCount(collapsed:count:)`
  (trailing slot while collapsed).
- **The band grows only when it must**: a bare (non-repo / unknown) header keeps the measured 24pt
  otty band (`minHeight`); a git-lined one takes its natural two-line height. Collapsed headers
  fold back to one line — count trailing, git folded away with the rows.
- The header HStack aligns `.firstTextBaseline` so the chevron + folder glyphs sit on the NAME
  line, not the two-line block's center.

### The idle row's "Terminal" becomes the last long-running command (2026-07-24)

The user: the kind-generic "Terminal" — what every at-root idle shell resolves to under By-Project
grouping (folder name suppressed by the header, bare shell suppressed as no better) — carries no
information; every resting pane in a section reads as identical twins. An idle shell has no CURRENT
identity, but it has a HISTORY one: the command it last ran is exactly what you scan the sidebar
for ("the shell I ran `make check` in").

- **Empty-title fallback = the pane's last long-running command** —
  `RailRowsBuilder.lastCommandTitle(blocks:)`, resolved in the LIVE row leaf (`SidebarLiveRow` +
  the iOS twin) since blocks are volatile; the memoized structural `RailRow.title` stays "" (search
  keys unchanged). "Terminal" now survives only for a genuinely blank shell that has run nothing —
  where it truthfully means "empty pane".
- **A sub-3 s command never takes (or clears) the title** — user-directed filter so quick commands
  don't churn the row: the resolver scans BACKWARDS for the newest block
  with `durationMS ≥ 3000` (`commandTitleMinDurationMS`, mirroring the busy-dot reveal default), so
  a quick `ls` after a long build leaves the build's title standing instead of flashing the row.
  A running block (no duration yet) never titles; an interrupted block with a stamped duration does.
- The tooltip's title-echo gate already covers the new title: a running command equal to the shown
  last-command title is dropped as a restatement.

### Row titles v4.5 — intent for agents, failure-only for shells, double-click rename (2026-07-24)

The last-command title above shipped and immediately under-delivered: echoing WHAT ran is mechanical
identity, and the research pass (tmux/WezTerm/kitty/iTerm2/Warp/VS Code/Ghostty + the agent-session
managers) shows the only label that stays meaningful AND differentiating once a pane idles is
SEMANTIC — why the pane exists, not what last executed in it. Three moves, one title chain
(`RailRowsBuilder.liveRowTitle`, shared by the macOS + iOS leaves): **rename → agent intent →
structural title → failed-command alarm → kind-generic**.

- **Agent rows title by their session INTENT (wire type 36, `agentSessionIntent`)** — the session's
  first titleable prompt, latched host-side by `ClaudePaneDetector` from the `UserPromptSubmit`
  hook's `prompt` field (no transcript reads, no LLM). Sticky per hook `session_id` (a new session /
  `/clear` re-derives; later turns never churn the row), cleared on `SessionEnd` AND on presence
  termination (a dead claude must not squat its task line on the pane), change-edge deduped with a
  silent-when-never-spoke anchor, re-asserted on reattach (the 33/34 sibling), pruned with the other
  per-pane mirrors. Slash-commands / harness-XML first prompts have no titling value — the latch
  stays open for the first REAL prompt. This is the Claude-Code/Conductor/VibeTunnel session-naming
  idiom: four `claude` rows in one project stop reading identically.
- **The idle shell's last-command title narrows to FAILURES only** — `lastCommandTitle` now lets the
  newest long-running (≥ 3 s) block DECIDE: non-zero exit surfaces its command in the status-error
  ink with a text-presentation `✗` (the `✳` precedent); a clean exit keeps the quiet generic row
  (success is the badge's story — echoing every finished command churned without informing, which
  is what sank v4.4). Sub-threshold blocks still neither title nor clear; an interrupted block
  (duration stamped, no exit code) decides quiet.
- **Double-click opens the inline rename** (`SlateTabRow`, the Finder idiom) — the third affordance
  sharing the context-menu / ⌘R pending-rename; the single-tap select rides `simultaneousGesture`
  so selection never waits out the double-click window. Rename stays the top of the chain and,
  once set, permanently beats the automatic titles (the tmux `rename-window` contract).

### Row titles v4.6 — the failure alarm retires; the title is simply the last EXECUTED command (2026-07-24)

The v4.5 fail-only title survived one day of hands-on: a red `✗` row reads as ugly alarm chrome,
and the quieter cost was worse — while a command RUNS the row showed only the spinner, answering
"something is happening" but never "what". User verdict: show the last executed command, and the
running command counts as last-executed.

- `lastCommandTitle` returns to exit-AGNOSTIC (the v4.4 rule), with the threshold LOWERED to 1 s
  (user-directed): the newest ≥ 1 s finished block titles the idle row; sub-second chatter still
  neither takes nor clears it. The title threshold now deliberately sits BELOW the busy-dot's 3 s
  reveal — standing text is cheap, the dot is an attention signal. Exit status lives where it
  always did — the badge and the tooltip's `cmd · duration · exit N` line. The `✗` glyph +
  status-error ink leave `SlateTabRow`.
- The chain gains a RUNNING rung above history: `liveRowTitle` = rename → agent intent →
  structural → **running command** → last executed → generic. The running text is the open
  block's command (foreground-process fallback), gated on the busy-badge reveal (`.commandRunning`
  / `.commandBusy`) — it appears WITH the spinner (the busy reveal), so a fast `ls` never flashes
  the title and the spinner is never anonymous again. The tooltip's running line drops as a title
  echo (the existing restatement gate).

### Row status v4.7 — the busy spinner retires; "working" is the TITLE's stepped shimmer (2026-07-24)

The rays spinner spent the trailing slot on motion and said nothing the title didn't already say
(the running rung has carried the full command since v4.6) — and it hid the shell label while a
command ran. New reading: any BUSY tier (`TabBadgeKind.isBusyTier` — working agent / OSC 9;4
progress / plain busy shell) renders as a working shimmer on the row TITLE itself (`WorkingShimmer`:
a low-contrast DARK band sweeping the title's own ink, quantized to 24 discrete steps over 1.4 s
with a 1.0 s rest beat — the coder/mux sidebar recipe, `steps()`-mechanical like T3 Code, never a
bright ChatGPT-gloss loop). The trailing slot keeps the shell label while running, so busy costs no
information. Glyphs are now reserved for the states that WAIT on the user (hand / triangle / check /
dot) plus the privilege markers (`#` / `∞`); the spinner mapping stays in `TabBadgeView` as the
vocabulary for non-sidebar mounts. The busy reveal threshold (1 s, `tabBadgeBusyDelaySeconds`) now
gates the shimmer + running title together; the terse busy reading ("Agent working" / "Running")
moves to the title's accessibility value. Both sidebars (macOS + iOS) split on `isBusyTier` at the
row leaf; phase math is pure wall-clock against a fixed epoch, so every working row ticks in unison
and re-renders can't reset a sweep.

### Row status v4.8 — hooks tell the truth: live intent, structured blocks, title-corroborated liveness; shimmer is the AGENT's alone (2026-07-24)

Three fidelity gaps closed after studying how the reference products supervise Claude Code
(t3code drives the Agent SDK's in-process `canUseTool` gate; herdr keeps ONE identity hook and
reads liveness off Claude Code's own OSC title — both refuse to let subagent events revive an
idle pane):

1. **The intent (wire 36) follows the session's LATEST titleable prompt.** The v4.5 latch kept
   the FIRST prompt for the session's whole life, so a multi-turn session's title never followed
   the work. `foldIntent` now re-derives on every real prompt; slash-commands / harness XML
   neither re-title nor wipe. The wire shape is unchanged (change-edge dedupe already handled
   re-pushes).
2. **Blocked/failed states arrive structurally.** The installer adds `PermissionRequest` (the
   structured permission dialog — kind 1, the gated tool names the label) and `StopFailure`
   (API-error termination → done with the error text, instead of a pane stuck `working`);
   `Notification` classification reads the structured `notification_type` field first
   (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog` block;
   known informational types never false-block; unknown types still fall to the text
   heuristics). `PreToolUse` of `AskUserQuestion` maps to waiting-for-input with the question
   as the label — Claude ASKING is not Claude working (the t3code/herdr special case).
   SubagentStart/SubagentStop stay deliberately uninstalled (the herdr bug class: a subagent
   completing after the main turn stopped must never revive an idle pane).
3. **Claude Code's own OSC title corroborates liveness.** The title the CLI writes (a Braille
   spinner glyph while a turn runs, `✳ ` at rest) folds into the ONE detector on every sniffed
   title edge: the spinner promotes a DETECTED claude to working, the rest prefix demotes ONLY
   a live `.working` back to `.idle` — the missed-Stop stuck-shimmer corrector. A title never
   conjures presence, never clears a hook block, never touches `.done`'s decay window, and
   never opens the type-27 stream on an undetected pane.

Sidebar reading refined with the states now trustworthy: the working shimmer is reserved for
the AGENT tier (`.running`) — a running COMMAND's title (the command text, standing still) is
signal enough, so `commandRunning`/`commandBusy` mount neither shimmer nor glyph and the slot
keeps the shell label. The shimmer itself steps up: a thinking agent's title wears the PRIMARY
ink (the brighter base lifts the row) and the dark band deepens (0.55 → 0.35) — the field
verdict on v4.7 was "barely there". The header git line drops the ASCII-only constraint:
`↑2 ↓1 +3 !4 ?5 ~1 $2` (the prompt-theme dialect — `~` replaces the misleading `=` for
conflicts) behind an inline `arrow.trianglehead.branch` glyph.

**Amendment (same day, field bug):** the Claude Code NATIVE installer names its executable by
VERSION (`…/.local/share/claude/versions/2.1.218`) — the exact-basename `claude` classifier never
matched, so presence never held, the 30 s post-hook grace lapsed between turns, the intent was
wiped, and the slot read a meaningless `2.1.218`. `ForegroundProcessDetector.canonicalName(of:)`
resolves a version-shaped basename up past the layout components (`versions`/`bin`/`current`/
`libexec`) to the owning app directory; the probe and the detector fold both use it. Verified
end-to-end on the rig with the real binary (row reads `✳ <latest prompt>` + slot `claude`).
The git line's inline branch glyph was also dropped on review — symbols only where they carry
meaning, and the sigil dialect already says "git".

### Row title v4.9 — the row title is claude's OWN title; an untouched rename commit is a cancel (2026-07-24)

Field bug behind "title vẫn là Terminal" after v4.8.1: the pane's persisted spec carried
`userRenamed: true, title: "Terminal"` — the inline-rename field (double-click, new in v4.8.1)
committed its UNEDITED seed on blur, freezing the resting generic title as a sticky rename that
outranks every live rung forever. The host latched the intent correctly the whole time; the rig
never reproduced because a rig pane has no accidental rename. Two guards:

1. **An untouched draft resolves as CANCEL** in both inline-rename fields (macOS row + shared
   `InlineRenameField`): only an actual edit expresses a rename — double-click then click-away
   leaves the live title chain in charge.
2. **A "rename" equal to the kind-generic fallback never wins** in `liveRowTitle`: renaming a
   pane "Terminal" carries no identity, so the rung yields to the live chain — which heals the
   already-persisted accidental pins without a migration.

And the round's ask — "lấy title CHUẨN của claude code" (research: herdr corpus, happy/happier,
opcode/crystal/claude-squad/vibetunnel, official docs): Claude Code already titles its own
session — the OSC title's text behind the telltale glyph IS a background-model topic summary
(and `/rename` writes a custom name there); "✳ Claude Code" is only the startup static. The
transcript's `type:"summary"` record (what happy/happier read) is resume-time-stale and an
internal format — the OSC title is the LIVE self-title and the sniffer already latches it. So
wire 36 now carries: claude's own topic when the title has one (`topicLine` — telltale/VS/space
stripped, "Claude Code" rejected, detected-pane-only), superseding the prompt-derived intent;
the prompt remains the fallback while no topic exists (short sessions, title generation off).
This is exactly the tmux `set-titles-string "#T"` behaviour the pane titles came from — the
pane shows what the program running in it says it is doing.

Addendum (same day): the resting fallback of a bare pane is the cwd FOLDER NAME, not the
kind-generic "Terminal". The at-root idle shell used to fall all the way through (folder name
suppressed because it restates the section header; "zsh" suppressed as meaningless) and land on
"Terminal" — which says even less than the folder. `liveRowTitle` gained a `cwdTitle` rung
between the last-command history and the generic fallback: the basepath is still an identity,
even when it repeats the header. "Terminal" now appears only while the pane has no cwd at all.

## Notifications: one banner per agent event + visibility-honouring gates (2026-07-24)

- **Decision (host, type-25 gate):** while a pane's agent status is HOOK-established
  (`ClaudePaneDetector.suppressesChildNotifications` = the existing `hookAuthority`), the agent's
  OWN terminal notification (OSC 9 / 777 / 99) is DROPPED at the sniff point
  (`MuxChannelSession.ingestPTYChunk`'s FIFO filter — the same chokepoint that already strips the
  raw OSC-7 `.cwd`). A hook-free pane keeps the OSC path untouched.
- **Why:** Claude Code titles under `TERM=xterm-ghostty` resolve its notification channel to
  `ghostty` and it posts its own OSC terminal notification for the very edges the hooks already
  report (permission prompt, idle/waiting) — so a hooked pane raised TWO system banners per event:
  the type-27 agent edge (`agentAwaitInput`/`agentTaskComplete`, rich, host-truth) plus the blind
  OSC copy riding type 25 through the "Allow App Notifications" master. The OSC copy predates the
  hooks (it was the only signal then) and is pure duplication once hook truth exists. Host-side
  suppression (not client de-dupe) because the authority signal lives host-side and is
  race-free: `hookAuthority` is set from the FIRST hook fold (SessionStart), long before any
  mid-session OSC 9 arrives; a timing-window de-dupe on the client would have to guess. The gate
  dies with the authority (SessionEnd / absence termination), so whatever runs in the pane next
  gets its OSC notifications back.
- **Decision (client, visibility gate):** the `NotificationPolicy` foreground-gate input is now
  `sourcePaneVisible` — the user can SEE the source pane (any split of the active session's
  ACTIVE tab while the app is active, or its satellite window is key) — computed by
  `WorkspaceStore.isSourcePaneVisible`. `.tabUnfocused` therefore honours its own label ("Only
  when source tab is unfocused"): previously it read LEAF focus, so a visible split you were
  watching still bannered. The completion BADGE keeps the narrower leaf-focus gate (a badge on a
  visible-but-unfocused split is signal, not noise).
- **Decision (client, toast focus gate):** the in-app toasts (explicit OSC, agent attention,
  long-command) are suppressed when the SOURCE pane is the focused leaf — the user is watching
  the event happen in the pane itself; a toast on top of it is noise. Unfocused panes (other
  splits, other tabs, backgrounded app) keep their toasts — on iOS the toast is the only
  notification surface.
- The OS-banner defaults are unchanged: app frontmost + `Notify While Foreground = Off` still
  suppresses every banner; a backgrounded app still always delivers (that is what notifications
  are for).

## Agent liveness in the sidebar: shimmer keys on RAW status, done is CLIENT-owned unreadness, titles trust the program (2026-07-24)

Field report against a live claude session: no shimmer while the agent thinks, no done marker
after the turn ends (despite the OS notification firing), an idle shell wearing a meaningless
"zsh" trailing label, and `vi .` out-titling nvim's own title. Root-caused against the actual
sources of herdr (`ogulcancelik/herdr`) and t3code (`pingdotgg/t3code`) rather than guessed —
both converge on the same model, now adopted:

- **Decision (resolver): the AGENT finish outranks the busy tiers.** `TabBadgeResolver` checks
  `agent == .done` (and the new `unseenAgentDone` latch) BEFORE `progress`/`isBusy`. The `claude`
  process holds the shell's OSC-133 block open for its entire interactive lifetime, so `isBusy`
  is true for hours; with the old order the completed/finished branch was unreachable on a live
  agent pane — the green check could literally never show. A plain COMMAND's `.success` stays
  BELOW the busy tiers (there a newly-running command genuinely supersedes the previous exit).
  Consequence deliberately accepted: an agent finish now also outranks the passive privilege
  badges (cup/shield) — attention over rest.
- **Decision (store): "done" is UNREAD-COMPLETION, owned by the client.** The host's status
  machine decays `done → idle` after seconds — correct for "what is claude doing", useless for
  "has the user seen it". New `WorkspaceStore.paneUnseenDone` latches at the `.done` edge when
  the pane is NOT visible (`isSourcePaneVisible` — the same tab-level visibility the
  notification gate uses; a finish you watched happen is pre-seen and only flashes), survives
  the host's idle push, and clears ONLY on visiting (the existing `selectTab`/`clearAgentBadge`
  acknowledge paths) or on new agent activity (`.working`/`.needsPermission`). This is t3code's
  `hasUnseenCompletion` (`completedAt > lastVisitedAt`, cleared by opening the thread, Done shows
  indefinitely) and herdr's `Idle && !seen` (seen set by viewing the tab, no timers) — "done" is
  a bit ORTHOGONAL to status, not a fifth state to keep alive host-side.
- **Decision (render): the working shimmer keys on the RAW `.working` status,** not the gated
  badge. "Badge while processing" (default OFF) masks `.working` out of the badge resolver; the
  V4.8 shimmer gate read that gated badge, so every default-settings install rendered a thinking
  agent exactly like an idle shell — the report "no shimmer while claude thinks". The toggle
  governs the badge GLYPH; the shimmer is the title's own affordance (t3code ships working-state
  motion unconditionally). Bonus: the shimmer now starts the moment `UserPromptSubmit` folds
  (t3code flips to working on submit), with no busy-reveal delay.
- **Decision (trailing slot): bare login shells show NOTHING.** The slot now shares the title's
  `processDisplayName` suppression (`shellLabel` deleted) — an idle row labelled "zsh" says as
  little as "Terminal" did; herdr never shows a shell name anywhere. A real foreground program
  (`claude`, `vim`, `ping`) still labels the slot.
- **Decision (title): a FRESH program-set OSC title beats the raw command line.** New
  `liveRowTitle` input `programTitle`: the pane's OSC title, surfaced only where the RUNNING rung
  would title the row, and only when the title was stamped AT-OR-AFTER the current command's
  start (`paneTitleAt` vs `paneCommandStartedAt` — a title left behind by an exited program
  never resurfaces on the next command). One leading agent-activity glyph (braille frame /
  `·✢✳✶✻✽`, herdr's `stripped_terminal_title` rule) is stripped. A FOLDER structural title still
  never yields. nvim ships `notitle` by default — the host-side nvim config now sets
  `title`+`titlestring`, so `vi .` rows read "file (dir) - nvim".

Client-only (no wire change, no hostd redeploy, golden untouched). NOT adopted, recorded for
later: herdr's screen-region rule engine (blocked-form regex, transcript-viewer freeze rules) —
our hook+OSC-title chain covers those edges today; revisit if hook drift appears.

## Agent liveness round 2: elapsed turn clock, one quiet finish dot, the idle nudge is not a block (2026-07-24)

Same-day follow-up on user feedback against the shipped round above.

- **Decision (trailing slot): a WORKING agent row's slot shows the live ELAPSED turn time, not the
  process name.** While the title shimmers, "claude" in the slot repeats what the `✳` marker + the
  shimmer already say — the duration is the one thing the eye wants from a busy row. New
  `WorkspaceStore.paneWorkingSince` (stamped on the genuine `.working` edge in `setAgentStatus`,
  never reset by same-status re-pushes, retired on leaving `.working`, pruned on reconcile) feeds
  `SlateTabRow.workingSince`; the slot mounts a 1 Hz `TimelineView` rendering
  `RailRowsBuilder.workingElapsedLabel` (`42s` / `2m15s` / `1h02m`, monospaced digits, skew clamps
  to `0s`). The tick invalidates one small text leaf per second — never the sidebar body.
- **Decision (badge vocabulary): BOTH clean-finish tiers render the small green dot; the filled
  `checkmark.circle.fill` is retired.** The 16pt filled check-circle sat visually heavier than
  every other reading in the muted row (user: "lạc quẻ" — out of tune); "unread finish" needs a
  marker, not a trophy. `StatusPresentation.tabBadge` maps `.completed` and `.finished` to the
  same 7pt dot; the completed/finished SPLIT stays semantic (freshness machinery, control-backend
  badge tokens, attention ranking) — only the glyph unified.
- **Decision (host classify): Claude Code's `idle_prompt` Notification ("Claude is waiting for
  your input", fired ~60 s after a turn ends with the agent resting at its prompt) classifies
  `.other`, NEVER `.waitingForInput`.** It re-raised the act-now orange hand on every pane the
  user had already read — minutes after the done marker cleared ("xem rồi thì thôi chứ"). Idle
  is presence, not a block. The matcher/message-text idle promotions described exactly this nudge
  and demote with it. Genuine blocks keep the hand through their own signals: `PermissionRequest`
  / `permission_prompt` / permission message text, `AskUserQuestion` (W10 adapter),
  `agent_needs_input`, `elicitation_dialog`. Wire vocabulary unchanged (kind byte 2 still exists;
  hostd redeploy required for this one — the classifier is host-side).

## Agent liveness round 3: a keystroke into a blocked pane is the Esc-cancel unblock edge (2026-07-24)

Same-day follow-up: with the idle nudge demoted (round 2), a REAL block that the user resolves by
pressing Esc left the orange hand up forever — Claude Code fires NO Stop hook on a user interrupt,
and (per herdr's claude manifest priorities: blocked-screen rules 840–980 sit ABOVE the ✳/9;4;0
idle rules at 250) the ✳ rest title already shows WHILE the dialog is open, so neither hooks nor
the title carry an unblock edge for the cancel path.

- **Decision: the host folds client→PTY input into the ONE detector as the unblock signal.** New
  `ClaudeSignal.userInput`: a user keystroke while the machine sits at `.needsPermission` demotes
  to `.idle` — a modal being typed at is being HANDLED. The convergence is what makes it honest:
  an ANSWERED dialog re-promotes to `.working` via its own PreToolUse a beat later; an Esc-cancel
  leaves idle standing (the truth). Every other status ignores the signal (typing a prompt /
  queued message never touches the shimmer; input never conjures presence or cuts the done decay).
  Fed from both input paths — the data-channel relay and the agent-control raw injection (the
  supervision cockpit's routed answer).
- **Decision: only genuine KEYSTROKES count — `PaneInputClassifier` excludes the terminal's
  automatic replies.** The same input frames carry focus-in/out (`CSI I`/`CSI O` — sent by merely
  VISITING the pane), CPR/DA/DSR/DECRPM/kitty-flags reports, OSC/DCS string replies, and SGR
  mouse-wheel events; none is a human handling the dialog, so none may drop the hand. A bare
  trailing `ESC` is the Esc KEY (legacy encoding), not a truncated report; kitty-encoded keys
  (`CSI 27 u` et al.) count. Truncated/malformed sequences classify conservatively as
  not-a-keystroke. Accepted edge: navigating a dialog's options and leaving WITHOUT answering
  also drops the hand — the user demonstrably saw the block (t3code's seen-semantics).

## Agent liveness round 4: port herdr's manifest screen-rule engine (2026-07-24)

> The user's directive: herdr's detection is complete and battle-tested — study it thoroughly and
> port it to Swift at 100% parity or better. herdr is Apache-2.0 (`ogulcancelik/herdr`); the port
> is a reimplementation from its `src/detect/` + `src/pane/agent_detection.rs` semantics, and the
> 19 agent manifests are carried verbatim.

- **Decision: the detect engine is a pure manifest-driven rule engine in `SlopDeskAgentDetect`.**
  TOML manifests (herdr's exact files, embedded as raw-string literals — no SwiftPM resource
  bundle, so the headless daemon and every app target load them with zero deployment surface)
  are parsed by a minimal TOML-subset parser, validated with herdr's exact limits (≤128 rules,
  gate depth ≤8, ≤512 gates, ≤32 matchers/gate, ≤1024 matchers, ≤512 chars/matcher,
  `skip_state_update` ⇒ `state="unknown"` + no visible flags), compiled to NSRegularExpression
  (case-sensitive unless the pattern opts in via `(?i)`, `contains` always case-folded), and
  evaluated with herdr's exact reduction: every rule evaluated, highest priority wins,
  first-declared wins ties, known-agent fallback = plain `idle`. All 13 region resolvers are
  ported byte-faithfully, including the `\n`-only line/offset math. Deferred (documented deltas,
  not parity gaps we hide): remote manifest auto-update and local override files — bundled
  manifests only.
- **RE-SCOPE of "screen verb = on-demand, NOT a persistent grid": the grid becomes RESIDENT per
  pane — but never on the hot path.** P6's original objection (scanning per chunk on the
  latency-critical read-loop thread) still stands, so the read loop only APPENDS the chunk to a
  bounded pending buffer (one Data append, same cost class as the journal/sniffer taps it sits
  beside). A dedicated scan task — herdr's exact cadence: 300 ms, tightening to 100 ms while a
  working→idle hold is pending — owns the `TerminalScreenModel`, drains the buffer, feeds the
  grid + a ported OSC title/progress tracker, extracts herdr's detection text (visible rows from
  the bottom, per-row trailing trim, trailing blank rows dropped, `\n`-joined), and runs the
  engine. Pane resize or buffer overflow marks the model dirty; the scan task rebuilds it by
  replaying the scrollback ring (the same repaint property the `screen` verb relies on). The
  idle-scan skip (idle + no new bytes ⇒ no regex work) is ported as-is.
- **Decision: hooks stay — screen verdicts join the ladder as continuous ground truth.** herdr
  runs Claude with NO state hooks (screen+OSC is its sole authority); we keep our richer
  hook edges (instant working on UserPromptSubmit, `.done` on Stop) — that is the "better" half
  of parity-or-better. Reconciliation in the ONE machine: a screen `blocked` raises
  `.needsPermission` (manifest-sourced); screen `working`/visible-`idle` may clear even a
  HOOK-sourced block once the block is ≥1 s old (younger blocks win — covers the ≤300 ms
  stale-snapshot race right after a hook fires, before the dialog paints); a plain (non-visible)
  idle never clears a hook block; `.done` keeps its decay (screen has no done concept);
  `skip_state_update` (transcript viewer / model picker) freezes the previous status, exactly
  herdr. The working→idle hold (3 consecutive confirmations at 100 ms, 700 ms hard cap,
  bypassed when the idle is VISIBLE chrome) is ported into the fold.
- **Decision: process identity gains herdr's job-scan — but only when the cheap probe is blind.**
  The 1 Hz `tcgetpgrp`+basename probe stays primary. When it returns a generic runtime/shell
  (`node`, `python3`, `sh`, … — the npm-wrapped `claude` case), the host deep-scans the
  foreground process GROUP (proc_listpids + KERN_PROCARGS2 argv), unwraps runtime argv with
  herdr's exact rules (bail on `-c`/`-e`/`-m` eval flags — never trust positional args after
  them; basename → known-package sniff → symlink resolution), and scores candidates
  (unwrapped 3 > literal agent 2 > other 1, first wins ties). This closes the documented
  wrapper-staleness hole from the round-`461` fix. The pure identification/unwrap logic lives in
  `SlopDeskAgentDetect` (injected filesystem resolver); only the pgroup/argv probe is host OS
  code, compiled-only per the hang-safety rule.
- All 19 manifests ship (claude, codex, gemini, opencode, cursor, …), so any of herdr's
  screen-manifest agents in a pane gets live status — presence generalizes from exact-`claude`
  to the ported agent alias table. Parity checklist = herdr's `detect/manifest/tests.rs` +
  `agent_detection.rs` test suites, ported to XCTest.

## Herdr port addendum: parity proven by differential, not asserted (2026-07-24)

The round-4 port claimed 100% parity on the strength of ~90 ported fixture tests. That
standard is now mechanical, not manual:

- **Decision: the parity contract is a differential harness against the REAL herdr binary.**
  herdr ships its own offline oracle — `herdr agent explain --file … --agent … --json` runs
  the actual rule engine on an arbitrary screen file and dumps the full evaluation trace
  (winner, per-rule matched flags, per-rule region byte length + preview). A new dev-only
  `slopdesk-detect-explain` executable mirrors that trace over `AgentManifestCatalog`, and
  `scripts/herdr-differential.py` diffs the two field-by-field on a deterministic generated
  corpus (~3.5k screens built from each manifest's own vocabulary — fragment mutations, CRLF/CR
  endings, prompt boxes, codex markers, Unicode case-fold probes — × own agent + 2 others ≈
  10.6k cases). Any divergence in a region resolver, gate, priority tie-break, or fallback
  surfaces as a field mismatch. XDG dirs are sandboxed per run so the oracle can only load
  bundled manifests.
- **It caught two real bugs on its first run** (both invisible to the ported fixture suite,
  both `\r`-class): Swift's grapheme-based `split(separator: "\n")` treats `\r\n` as ONE
  `Character` and never splits CRLF text; and Rust's `str::lines()` strips a trailing `\r`
  only after stripping `\n` — a final unterminated line keeps its `\r` (plus Rust `trim()`
  counts `\r` as whitespace where Foundation's `.whitespaces` does not). `RegionText.rustLines`
  is now byte-level and pinned by `ManifestRegionLineSemanticsTests` (fixtures verified against
  the oracle). Dormant in production — VT grid rows never contain raw `\r` — but real for any
  future direct-text feed, and exactly the class of drift the harness exists to catch.
- **Decision: upstream sync is a script, not a ritual.** `scripts/herdr.pin` records the herdr
  commit the port is PROVEN equivalent to (advanced only after a green differential run).
  `scripts/herdr-sync.sh` = fetch → show `src/detect` delta since the pin → regenerate
  `BundledAgentManifests.swift` verbatim via `scripts/gen-bundled-manifests.py` (which fails
  loudly if the manifest SET changes, and byte-reproduces the checked-in file — proving the
  bundled TOMLs match the pin) → rebuild the oracle (vendored libghostty-vt builds with the
  repo's pinned Zig 0.15.2 + xcrun SDK shim from `ThirdParty/ghostty`) → differential →
  Swift test suite → `--update-pin`. Manifest-only upstream changes sync hands-free; engine
  `.rs` changes are flagged for a manual port, and an unread or botched port cannot pass —
  the differential gates the result against the new binary itself.

## One-shape status circle, round 2: signature readings (2026-07-24)

The badge vocabulary consolidated onto ONE Ø12 circle (`0a6e8bd6`): every lifecycle state is a
hue/fill reading of the same silhouette (the otty per-state symbol set — rays spinner, raised
hand, warning triangle — is retired), and the iOS toolbar + Peek & Reply header mount the same
`StatusRing` instead of their SF-symbol set. On review the individual readings still looked
STOCK — a dashed 8-segment spinner is every loading indicator since Aqua, ring+halo is a
recording dot, ring+✕ is a generic error glyph. Round 2 keeps the one-shape contract (the
`Reading` enum, the mapping, and every pin are unchanged) and swaps the drawing of the three
dynamic readings for shapes in the app's own dialect:

- **working = the COMET arc**: one ~110° arc whose tail fades to nothing (angular gradient in
  the shape's own space), sweeping the ring smoothly (1.4s/rev, wall-clock phase — remounts
  land mid-revolution). Replaces the ticking dashed ring; motion reads as one object in
  flight, not a segmented spinner.
- **awaiting = the blinking cursor dot**: the solid ring holds steady while the 5pt centre dot
  hard-blinks on the terminal cursor's cadence (0.53s phases, on/off cut — never a fade). An
  awaiting pane IS a prompt with a parked cursor; the badge borrows exactly that signal. The
  stepped halo (recording-dot cliché) is deleted.
- **error = the BROKEN ring**: the circle itself with a ~50° gap bitten out (round caps, gap
  at the top-right), static and red — "the loop broke". The inner ✕ is deleted; the failure
  state is the only reading whose silhouette is damaged, which is the message.

`resting` (thin muted ring) and `done` (the established green 7pt filled dot) are unchanged;
`#`/`∞` stay text. Client-only, no wire change; pins untouched by design (they assert reading
CLASSES, not pixels).

### Round 3 — the circle yields to the terminal dialect: `AsciiStatusBadge` returns as `StatusGlyph` (2026-07-24)

Round 2's drawn readings (comet arc, cursor-dot ring, broken ring) still read as generic drawn
iconography on hardware review; the requested register is the TERMINAL's — status spoken as the
text a CLI would print. The v3 `AsciiStatusBadge` dialect (deleted by the otty reset) returns as
`StatusGlyph`, replacing `StatusRing` outright while keeping its surface contract (the `Reading`
enum + `TabBadgeStyle` mapping + the same three mount surfaces):

- **working = the AI-CLI asterisk pulse** `· ✢ ✳ ✶ ✻ ✽` breathing out and back (0.15s/frame,
  accent) — the agent's own spinner vocabulary.
- **busy = the braille dot-walker** `⠋⠙⠹…` (0.1s/frame, muted) — the shell's spinner. The busy
  tiers now split by VOICE, not just hue: `.running` speaks agent, `.commandRunning`/`.commandBusy`
  speak shell (new `Reading.busy`; the pins split accordingly).
- **awaiting = `?`** amber bold, blinking full↔dim ink on the cursor cadence (0.53s hard duty
  cycle, never fully off — the question keeps its slot).
- **error = `✗`** red static; **done = `●`** green (the established quiet dot, now as the printed
  character — the ✓ stays retired); **resting = `·`** muted; `#`/`∞` unchanged.

All glyphs render in the instrument (mono) face inside the same fixed 16pt box; both spinners are
frame-stepped off a fixed wall-clock epoch (all spinning rows step in unison, re-mounts land
mid-cycle), and the frame function is pure + static, pinned headlessly
(`testSpinnerFrameCadenceAdvancesOnePerBeatAndWraps`). Client-only; no wire change.

### Round 4 — the glyph column dissolves: status becomes the title's INK (2026-07-24)

Round 3's text glyphs were the right register but the wrong anatomy: `?` / `✗` / `●` are three
unrelated characters sharing one slot, and the review verdict was that the rows that show NOTHING
(working = title shimmer, running command = still title, idle = bare) are the ones that look right.
Round 4 follows that conclusion to its end — the **ink dialect**: a sidebar row never mounts a
lifecycle glyph. The states that need the eye recolour the text that is already there, the same
move the working shimmer makes for motion:

- **awaiting input** — the title turns amber and BLINKS full↔dim on the terminal cursor's cadence
  (`cursorBlink`, 0.53s hard duty cycle, never fully off): the row waits the way a prompt waits.
- **error** — the title turns red, static (red text is what a terminal already means by red text).
- **completed/finished** — the title turns green until the pane is visited (the unread-mail move,
  spoken in the hue budget's unread-finish green).
- **motion/idle** — unchanged: shimmer for a thinking agent, still text for a running command,
  secondary ink at rest. The trailing slot now belongs ONLY to the shell label / elapsed readout /
  privilege markers (`#`/`∞`, the sole remaining `TabBadgeView` renderings) / hover `×`.

One mechanism everywhere the status shows: the sidebar row, the iOS row, and the title-menu
NEEDS-ATTENTION rows (which drop their leading badge for a tinted title via `SlatePopoverRow`
`titleInk`) all speak `StatusPresentation.attentionInk`, and the titlebar pip reuses the same map —
the ink can never disagree with itself. `StatusGlyph` survives only where a compact single-pane
agent readout has no title to tint (iOS toolbar, Peek & Reply header), shrunk to
resting/working/awaiting/done — the braille walker and `✗` readings are deleted with their last
mounts. AX: the state the ink speaks rides the title's `accessibilityValue`. Pins:
`attentionInk ⇔ needsAttention` exhaustively, no-slot-glyph for every lifecycle kind, only-awaiting
blinks. Client-only; no wire change.

**Round 4.1 — the blink dies too (2026-07-24).** The awaiting blink read as tacky on hardware
review. Every attention ink now holds STILL — one rule, aligned with MERIDIAN's hard-cut ethos
(animation is reserved for the sustained live signal, i.e. the working shimmer; a waiting state is
not motion). `CursorBlinkModifier` deleted with its mounts; `StatusGlyph`'s `?` is static bold.
The titlebar pip remains the roll-up cue for "something waits".

**Round 4.2 — the agent row's trailing text goes silent (2026-07-24).** An agent row's slot
carried the live elapsed readout while working ("42s") and the process name ("claude") at rest —
both redundant on review: the `✳` marker already names the agent and the shimmer already says
"working". Agent rows now pass `processLabel: nil` and the elapsed readout is deleted
(`workingElapsedLabel` + its pin); the slot on an agent row holds only a privilege marker or the
hover `×`. The store's `paneWorkingSince` turn clock stays (core state, pinned) — only its
rendering died. Duration, when wanted, belongs to the tooltip's richness, not the rail.

### Round 5 — the instrument rail: one alignment, one metadata voice, the ladder's beat (2026-07-24)

The states were settled (rounds 4–4.2); what still read as unimpressive was the COLUMN's craft.
Diagnosis (against the shipped layout, cross-checked with the strongest external references —
Slack/tmux weight-plus-ink, Things 3 quiet numerals, Cursor's elapsed-as-metadata, Warp's own
users asking for whole-row ink): three faults, none of them the vocabulary.

1. **The rail was broken.** Three unrelated left edges — "TABS" at x20, row titles at x18, and the
   section header's NAME at x46 (chevron + folder icon + gaps) — put the PARENT deeper than its
   children, the inverse of every outline. Now there is ONE text rail: list inset (`space2`) + row
   inset (`tabRowInset` = `space3`) lands the caps label, header name, git line, and every row
   title on the same x; the disclosure chevron hangs in the `tabRowInset`-wide gutter BEFORE the
   rail (the outline idiom), and the folder icon is deleted — the chevron already says "group".
2. **Metadata had no typeface law.** The git line, shell label, and hidden-row count rendered in
   the system face while the ping and privilege markers spoke mono. Now one rule (MERIDIAN L2):
   DATA — git line, process label, count, telemetry — is the instrument mono at the caption size
   on the tertiary ink; identity (titles, header names) keeps the system face. The header name
   steps up to semibold so the parent stands firmer than its rows.
3. **Off the ladder for no reason left.** `heightTabRow` drops 36 → `heightRow` (32, the ladder's
   single-line rung), `radiusTab` 7 → 6 (the control-radius family), `tabRowInset` 10 → `space3`.
   The otty measurements served the 1:1 port; the port is over. The active card's cast shadow is
   now LIGHT-theme-only — on dark, depth is the surface ladder (fill + hairline), and a
   dark-on-dark shadow read as a smudged edge.

Two additions on top of the alignment work, both inside the existing vocabulary:

- **Attention pairs weight with ink** (`SlateTabRow`): an amber/red/green title also takes the
  `.medium` step the active card uses — the Slack/tmux idiom (bold says "something changed", the
  hue says what), two signals on one scale, no new elements.
- **The collapsed count wears the roll-up ink** (`StatusPresentation.attentionRollupInk`): a
  folded group's hidden-row count borrows the strongest attention ink among the rows it hides
  (question > error > unread finish — the resolver's own precedence), so collapsing a project can
  never mute a waiting agent. No pill, no glyph — the number that was already there, in the hue
  budget that already exists. Pinned headlessly (`testAttentionRollupInkFollowsBadgePrecedence`).

Deliberately NOT taken from the research: a fourth state hue (every good reference caps at three),
left-edge accent bars (state is the title's job), a second metadata line per row (richness stays in
the tooltip), idle-age fading (Arc's move — deferred; needs per-pane last-activity state).
Client-only; no wire change.

### Round 6 — colour comes back on purpose: identity tints, ink washes, the footer lamp (2026-07-24)

Round 5 fixed the skeleton; the review verdict on it was "correct but bare": deleting the folder
icon left the headers anonymous, the states/selection read as text-only recolours, and the footer
was two grey words. Round 6 reintroduces colour — but only where it MEANS something, so the
minimal-indicator conclusion of rounds 4–5 stands.

1. **Project identity tints** (`ProjectTint` + `SlateTheme.projectTints`). Each section header's
   gutter carries an 8pt rounded-SQUARE swatch in a per-project colour (square deliberately — the
   dot shape stays the status language: attention pip, footer lamp). The colour comes from the
   THEME's own chromatic set (Monokai: cyan/purple/orange — the three that carry no status meaning;
   amber/red/green are excluded so a project can never read as a state), keyed by FNV-1a over the
   project key: launch-stable by construction (Swift's seeded `hashValue` would reshuffle per
   process — pinned in `ProjectTintTests`). The collapse chevron still exists: it trades places
   with the swatch under the pointer (Notion's outline idiom — identity at rest, affordance on
   approach). The keyless "Other" bucket keeps a neutral swatch.
2. **The attention wash** (`Slate.State.attentionWash`). An inactive row in an attention state lays
   its title's ink under the WHOLE row at film opacity — the whole-row wash Warp users ask for —
   while the title keeps carrying which state (ink + weight, unchanged). One source feeds both
   (`SlateTabRow.attentionInk`), so wash and title can't disagree. Hover stacks on top.
3. **The active card is accent-lit** (`Slate.State.activeWash`/`activeEdge`). Selection was one
   luminance step (raised fill + neutral hairline) — correct and invisible. The card now adds a
   low-opacity accent film and swaps its hairline to the accent: doctrine already reserves accent
   for the ACTIVE state, and the focused-pane corner mark speaks the same colour, so the selected
   row is the one accent-coloured object in the rail.
4. **The footer becomes an instrument block** (`ConnectionRailFooter`). The sidebar footer drops
   the compact host+ping line for a two-line block on the sidebar's own rail, rhyming with the
   section headers: a 6pt health LAMP in the `tabRowInset` gutter (green good / amber slow or
   dialing / red bad / dimmed offline, soft same-hue glow while lit — static, never blinking;
   colour rides the needle curve), the hostname on the text rail, and the mono detail line beneath
   (ping while connected, the short status word otherwise — `ledState`/`footerDetail`, pinned in
   `ConnectionClusterTests`). The titlebar + iOS mounts keep the one-line cluster. This is the one
   sanctioned dot besides the attention pip — the "no LED" note from the cluster's first pass is
   superseded for the footer only.

Hue budget after this round: three STATUS hues (amber/red/green — states), the ACCENT (active
selection + focus, one voice), and three IDENTITY tints (projects — theme chromatics, non-status).
Nothing blinks; no lifecycle glyph returned. Client-only; no wire change.

### Round 7 — monochrome restored, the folder returns (2026-07-24)

The round-6 verdict: WORSE — the standing colour (identity swatches always lit, an accent-washed
card always lit, a green lamp always lit) made the rail gaudy, and the missing folder was the real
round-5 complaint all along. Round 7 re-establishes the rule the ink dialect had implied: **the
rail is monochrome at rest; colour appears only when something needs a human** (amber waits,
red failed, green unread-finish, warn/err ping digits). Reverted wholesale: `ProjectTint` +
`SlateTheme.projectTints` (identity swatches — GONE, including the pinning tests),
`Slate.State.attentionWash` (whole-row washes — state went back to being the title's ink alone),
`Slate.State.activeWash`/`activeEdge` (the active card is again the raised fill + neutral hairline
— one luminance step IS the selection language). Identity-by-colour is a dead end here: three
tints across many projects collide, and a coloured square per header is decoration the moment you
stop reading it.

Kept from round 6, but muted: the footer's two-line rail block (`ConnectionRailFooter` — the
LAYOUT answered "the footer is two grey words" and stays), with the lamp recoloured to the
monochrome ladder: connected = secondary ink, dialing/offline = tertiary (the detail word says
which), warn/err ONLY while a live link degrades — and the glow deleted. `LedState` and the
`ledState`/`footerDetail` maps are unchanged (still pinned).

Follow-up, same day: the muted lamp still read as clutter — a status dot beside a status word is
the tell of template design, and the review called it exactly that. The dot is DELETED; the
footer is pure text on the rail (hostname + mono detail, indented onto the shared text x, the
gutter empty). `LedState` survives as the INK classifier only (hostname dims via `.dim`, digits
take warn/err) — the "no LED" doctrine from the cluster's first pass is fully restored.

Returned by request: the dim `folder.fill` in the header gutter (the pre-round-5 glyph), on the
header ink — the one pictogram the monochrome rail keeps ("a group is a place"). First pass kept
round 6's hover-swap (folder at rest, chevron on approach); the follow-up verdict was that a
lone folder still reads bare — so the header now wears the full otty trio, chevron AND folder
always visible before the name (the name indents past its rows again; the hover-swap died with
its `hovering` state). Client-only; no wire change.

### Round 8 — the mark returns: T3 Code's dashed ring, static (2026-07-24)

Round 4's "no indicator" verdict is reversed by request: with the trailing slot holding only
text, the rail read lopsided — the rows wanted a small fixed-width mark back at the right edge,
and the reference this time was T3 Code's sidebar. The first pass ported the WRONG generation:
Sidebar V1's pulsing dot (`animate-status-pulse`), rejected on sight — a blinking dot is exactly
the template tell the footer round already named. The CURRENT `SidebarV2` renders a STATIC dashed
circle (lucide `CircleDashedIcon`) for in-flight work, so the shipped mark is that: an 8-dash
ring whose dash period divides the circumference exactly (no seam), a 10pt fixed footprint at the
row's trailing edge, nothing animated. Working agent = accent (keyed on the RAW `.working`
status, the same route as the `.running` badge tier); running command = muted secondary. The
V1-vs-V2 confusion is the round's lesson: port the source's CURRENT surface, verified against the
clone, not a remembered screenshot.

### Rounds 9–10 — one shape, hue is the grammar; the title goes neutral (2026-07-24)

Round 9 killed the two survivors of the V1 misread: the solid "act-now" dot (SidebarV2's own
status ladder renders `icon: null` for approval/input/failed — the colored label is the whole
signal there) and the title's `WorkingShimmer` (with a mark present, motion on the text was doing
the same job twice — the component and its tests are deleted; nothing in the rail animates).
Round 10 then took the last step: the INK DIALECT on titles (round 4's core idea) retires. Every
state renders as the SAME dashed ring and only the HUE names it — accent working, muted busy,
green unread-finish, amber question, red failure — and the title never recolours (the neutral
ladder; attention keeps only the `.medium` weight bump, the mail-unread idiom). The solid
done-ring lost to consistency on review, so done rings dashed too — one shape everywhere.
`StatusDotStyle` collapses to an ink; `attentionInk` survives as the hue map the mark and the
collapsed-group rollup count share.

### Round 11 — attention leaves the titlebar (2026-07-24)

The titlebar's amber pip (and the NEEDS ATTENTION section inside its `⋯` menu) predate the ring
marks; with the sidebar now naming every waiting pane in place, a second attention surface on the
content side was duplication. Both are deleted — the centred title is bare at rest, and the menu
opens straight at WORKING DIRECTORY. The unseen-attention QUEUE underneath
(`WorkspaceStore.unseenAttentionPanes`) is untouched: ⌘⇧U's visited-set walk still rides it (its
tests renamed to `UnseenAttentionQueueTests`, every behavior pin kept). Cascade deletions with
the last consumer gone: `SlateStatusDot`, `SlatePopoverRow`'s title-ink override, the titlebar
snapshot fixture — and, in the follow-up audit sweep, the entry's host-label field (read only by
the deleted menu row) leaves `UnseenAttentionEntry`; `since` stays, it orders the queue.

### Round 12 — the footer stops being a dashboard: one status line, no rule (2026-07-25)

With the row list settled, the sidebar's last unexamined band was its footer: a hairline, then a
two-line instrument block (hostname over `12 ms · up 2h 14m`). The verdict on both halves —
the rule read cheap, and the second line was paying footer real estate for readings nobody acts on.

1. **The hairline is deleted.** The panel's own dialect already says how bands separate: the
   section headers carry "no caps, no rule — groups separate by the header band's own air". A
   `Slate.Line.subtle` rule at the bottom was the one seam in a sidebar that draws none anywhere
   else. The separator is now the `space3` gap above the row — the same inter-group band the
   groups use.
2. **The footer collapses to ONE line** (`ConnectionRailFooter`): hostname leading on the rows'
   text rail, metric trailing in the rows' status-mark column, so the footer reads as the list's
   last line rather than a widget bolted under it. The ink rules are unchanged — `LedState` still
   dims the host while nothing is connected and puts warn/err on the ping digits alone; a status
   WORD ("reconnecting 3/20") now takes the system face while a METRIC keeps the instrument mono,
   matching the compact mount's trailing slot.
3. **Link uptime is retired outright** — `footerExtras`, `uptimeLabel` and `AppConnection`'s
   `connectedSince` stamp all go with it (the readout was their only reader). "How long has this
   link been up" is a number you read once and never act on. The stream numbers do not move into
   the freed slot either: appending them is what truncated the hostname in the first place
   (`2850f842`), so fps/kbps stay tooltip detail on BOTH mounts.

The two mounts are now the same shape — host leading, metric trailing — differing only in their
insets and in the rail's willingness to say "connected" in the beat before the first ping sample
(the compact row stays silent there; a connected footer with an empty right edge reads as broken).
Deliberately NOT taken: a `+` New-Tab affordance in the freed space (the footer is status, not a
control strip), and a host-load readout (genuinely useful, but it needs a new host→client control
message — a separate scope, not a polish round). Client-only; no wire change.

### Round 13 — the second line comes back, this time about the MACHINE (2026-07-25)

Round 12's freed line is spent, on the one readout it explicitly deferred: the host's pulse.
The footer is two lines again, and the difference from the version round 12 killed is what the
second line is ABOUT. `12 ms · up 2h 14m` was more link: a metric nobody acts on, stacked under a
metric they do. `cpu 34% … mem 61%` is the other end of the wire — the machine you are typing into,
which you cannot see and cannot otherwise ask.

1. **New host verb: `hostVitals` (metadata verb 17, PATH 1).** A pure read, host-global and
   pane-agnostic like `hostInfo`, answering 3 bytes: `[cpu%][mem%][pressure]`. It rides the existing
   metadata RPC rather than a new push message — the client already owns a poll clock and a
   "through whichever pane has a live channel" resolver, so a push type would have bought nothing
   but a new wire surface. `AppConnection` polls it on the supervisor's own liveness clock at half
   rate (~4 s), fire-and-forget so a slow metadata reply can never delay the drop detection.
2. **CPU is a delta, so the host may answer "not yet".** Mach hands out cumulative counters;
   `HostVitalsSampler` banks a baseline, discards one older than 30 s (a window spanning a
   disconnect describes a machine that no longer exists) and repeats its cache for a call that
   arrives inside 1 s. `error` therefore means "ask again next poll", never a fabricated `0%` — and
   a missed poll leaves the last reading standing rather than blanking a working instrument.
3. **The rail still doesn't twitch.** A percent polled every 4 s jitters ±2 on an idle machine, and
   this rail has no animation by design. `HostPulse` deadbands each metric at 3 points: below that
   the row holds still, at or above it snaps to the sample EXACTLY (never a smoothed midpoint — the
   number shown is always one the host really reported). Pressure is exempt; a state change is not
   noise.
4. **Colour where it is earned.** The MEM run takes warn/err from the kernel's memory-pressure
   level, not from the percent (a high memory percent is ordinary — macOS fills the RAM it has;
   pressure is what predicts a machine about to crawl). CPU is never coloured at all: a build
   pegging the host is what the host is FOR, and a readout that goes amber every compile teaches the
   eye to ignore it. Exact numbers + the pressure word ride the tooltip, with the ping's fps/kbps.
5. **Absent, not blanked.** No reading ⇒ no second line — an instrument showing `cpu —` advertises
   breakage, while a footer that grows a line on connect just reports. Both lines share round 12's
   two rails, so the pulse sits in the same columns as the host name and the ping.

Wire change (a new verb + payload codec, golden-pinned); the daemon and the client both ship it,
and an old host answering `unsupportedVerb` simply stays one line.

**Round 13.1 — the metrics are named by their marks.** `cpu 34% … mem 61%` set the whole line in
lowercase prose, and read as a sentence adrift under the identity rather than as instruments. The
words are replaced by their symbols (`cpu`, `memorychip` — Activity Monitor's own pair), leaving
`▣ 34% … ▤ 61%`: a readout is a number and the thing it measures, and the thing it measures is the
one part that never changes, so it should be the part that is drawn rather than spelled. The two
marks differ in SILHOUETTE (square, pinned on four edges vs a wide module pinned on one), which is
the only distinction that survives at 11pt. Mark and digits carry ONE ink — when pressure colours
the memory reading the glyph turns with it, since a half-tinted readout reads as a rendering bug
rather than a warning. The words are not lost, they move to the surfaces that have room for prose:
the tooltip and the accessibility label, which cannot see a silhouette at all.

**Round 13.2 — free disk takes the middle rail.** Two runs on a 220pt line left a hole in the
middle, and the hole was worth a third reading rather than wider tracking: a host stops being useful
in exactly three ways — busy, full, out of room — and only the first two were reported. So
`hostVitals` grew a `[UInt32 disk free MiB]` field (7-byte payload; golden hand-merged) read from
`statfs` on the HOME volume, which on a modern Mac is the Data volume the work actually consumes
rather than the read-only system snapshot at `/`. Three consequences worth stating:

- **It is the one metric given in BYTES.** A disk percent lies in both directions — 2% of a 4 TB
  disk still builds, 8% of a 128 GB disk does not — so both the reading and its ink threshold are
  absolute (amber under 15 GiB, red under 5 GiB). There is no kernel "disk pressure" verdict to
  defer to the way the memory run defers to one.
- **Unreadable is not zero.** A full volume genuinely reports 0 MiB, so the failed-syscall case gets
  its own wire value (`UInt32.max`) and the run simply disappears — the two rails keep reporting. A
  metric that cannot be read must not take the working ones down with it, nor draw a full-disk alarm
  for a refused syscall.
- **The format is the deadband.** CPU and memory need one because a percent twitches; free space is
  rendered at two significant figures (`820M`, `6.4G`, `240G`), and a number that only names round
  values cannot twitch. Adding a threshold on top would have made the slowest metric also the
  laggiest.

**Round 13.3 — the three readings run fastest-moving to slowest.** Free disk went in at the middle
rail on the argument that the least-consulted metric belongs where neither rail is. Ordering by how
often a reading is *consulted* turned out to be the wrong axis; ordering by how fast it *moves* is
the one the eye already uses. So the line reads `cpu · mem · disk`: cpu changes second to second,
memory over minutes, free disk over days, and a glance travels from "right now" toward "next week"
instead of stepping over the slow reading to get to the fast one. It also keeps the two PERCENTS
adjacent — they are the pair a glance actually compares, and the odd reading out (the only one in
BYTES) now sits at the end where its different shape stops interrupting them. The tooltip and the
accessibility label speak the same order, so neither is a re-shuffle of the row. Nothing else moves:
the thresholds, the inks, the absent-not-blanked rule and the wire are all unchanged.

### Round 14 — the muted ring belongs to the agent, not to every busy shell (2026-07-25)

Round 8 gave the muted secondary ink to "running command", and in daily use that turned out to be
almost every row: any pane with something in the foreground — a dev server, a `tail -f`, a long
build — wore a mark. The ring stopped meaning anything, and the states that DO need the eye had to
compete with a rail full of quiet decoration.

The mark is now the AGENT's column. `StatusPresentation.statusDot` takes an `agentIdle` input (the
raw `ClaudeStatus.idle` verdict — a code agent PRESENT and at rest) and the muted ring is that
state's rendering and nothing else's; `.commandBusy` / `.commandRunning` mount nothing. Two things
this is not:

- **Not a resolver change.** `TabBadgeResolver` still fuses the busy tiers exactly as before — the
  control backend's badge tokens, the tooltip vocabulary and the title chain (which titles a busy
  row with its running command) all read them unchanged. Only the view-layer hue map narrowed.
- **Not a new signal for agent rows.** A resting `claude` pane already wore the muted ring, because
  the agent process holds the shell's OSC-133 block open for its whole lifetime and arrived here as
  a bare `.commandBusy`. That row looks identical; what changed is that a pane which is busy WITHOUT
  an agent no longer borrows the reading. The busy tiers keep falling through the same branch, so
  an agent at rest still rings whether or not it also carries a privilege marker.

A running command is already named by the row's own title, which is the more informative surface —
spending the mark on it too was the duplication round 9 removed from the title's shimmer, in the
other direction. Client-only; no wire change.

### Round 15 — the agent teardown edge: an announced exit must not be undone by a lagging one (2026-07-25)

`/exit` inside a pane left the row wearing Claude Code's title (`✳ <topic>`) and the agent's muted
ring for ~31 s. Measured on the wire with a mux-aware tee over six real exits, the tail was two
independent defects that happened to fire together.

**The grace paradox.** `SessionEnd` fires while `claude` is still the PTY foreground — captured at
1.0–1.5 s of overlap before the shell reclaims it. Across that gap every weak liveness signal still
sees an agent: the ~1 Hz foreground poll, the 300 ms screen scan, the OSC title still on the grid.
Any one of them lifted the presence floor straight back off `.none`, and the resurrection landed
34–440 ms after the pane went dark (4 of 6 exits; the other 2 were clean, which is what made it feel
intermittent). Worse, `ClaudePaneDetector.hook` stamped `lastAuthoritativeAt` on EVERY parsed
record, `SessionEnd` included — arming the 30 s window in which a foreground ABSENCE is suppressed.
So the one signal announcing the end was also what kept the dead state alive for the full window.

Two changes, in the two places that own the two halves. `SessionEnd` now CLEARS the stickiness
anchor instead of stamping it: the anchor exists to protect a live state from a poll that cannot see
a wrapper-launched agent, and a session that just ended has no live state to protect — the absence
about to arrive is the SessionEnd's own corroboration, not something to defend against. And
`ClaudeStatusMachine` gained a POST-EXIT FLOOR LOCKOUT: a hook `sessionEnd` arms
`postExitFloorLockout` (3 s, clearing the widest measured overlap), during which no weak signal —
presence, title, screen, manifest, an informational Notification — may lift `.none`. Only an
authoritative hook clears it, so `claude` relaunched immediately is never held dark. Presence
ABSENCE arms nothing: `processPresent(false)` is the end already observed, not an announcement of
one. This is herdr's process-exit primacy and t3code's `context.stopped` idempotence, expressed in
the reducer where both belong; the deliberate difference from t3code is that our terminating signal
is racy, so the veto has to be time-bounded rather than a plain flag.

**The orphaned title.** Claude Code DOES emit its own exit-time title clear — captured as
`OSC 0;` with an empty body — but `HostOutputSniffer` drops empty titles on purpose (zsh/p10k emit
them mid prompt-redraw), and the client dropped them a second time. A plain zsh prompt never
re-titles afterwards, so the agent's title had no way home. The fix is OWNERSHIP, not
guard-loosening: `ClaudePaneDetector` records that a DETECTED agent wrote the pane's title (the
spinner / `✳` / claude-naming shapes the machine already believes) and, on the agent-gone edge,
emits an explicit empty type-21 — a one-shot, scoped to titles the agent demonstrably owned, so a
shell's own `nvim — README.md` stays put. The host sniffer keeps dropping empty OSC bodies, which is
what makes an empty type-21 on the wire unambiguous; the client's duplicate guard is retired and it
now applies the retirement. The retirement also forgets the sniffer's coalescing anchor, since the
next `claude` in the same pane opens on the byte-identical `✳ Claude Code` and would otherwise be
deduped into silence. Titles that are OWNED and never decay is the one t3code idea that transferred
directly (`canReplaceThreadTitle`) — the difference is that t3code's titles are its own, so it never
needed the giving-back half.

Three adjacent gaps closed in the same pass:

- **A ctl-spawned pane had no agent detection at all.** `spawnStandalonePane` constructed its
  session without `agentDetectEnabled` and never threaded `SLOPDESK_SOCKET_PATH` / the pane id, so
  the one place an ORCHESTRATOR runs its agents was the one place they ran unobserved — no detector
  to fold into, and no hook route in. Both now match the mux path; `registerHookSink` gained a
  paneID-keyed form (a ctl pane's identity is its session uuid — there is no channel pair), and the
  key is retired on every teardown so a spawn no longer leaks a sink per pane.
- **The ctl `events` stream could not report the agent-gone edge.** `.none` and `.idle` collapse to
  the same supervision word by design, and the subscriber dedupes consecutive identical states — so
  a pane whose agent left emitted an `"idle"` byte-identical to the one it was already at, and the
  transition vanished. `AgentControlState.presence(from:)` carries that one bit alongside the state:
  it joins the dedupe key and rides the event as `agentPresent`. The four-state vocabulary the
  `report` verb validates against is untouched.
- **`Stop` carries `background_tasks`.** Undocumented in the hooks reference but present in the
  shipped payload (verified against the CLI binary), already filtered producer-side to
  running/pending backgrounded tasks. Parsed tolerantly onto `StopInfo.backgroundTaskCount` and used
  as the done-chip label ONLY when the turn ended without an assistant message — "3 background tasks
  running" beats an empty chip. Deliberately NOT a status change: the rest-title demote would undo a
  `.working` within a second, and no hook fires when a background task finishes, so any richer state
  this set would have no way home.

Rejected: a herdr-style DEFERRED clear (hold the teardown briefly in case the agent respawns, to
avoid flicker). The veto already prevents the flicker it targets — nothing resurrects, so nothing
flickers — and a settle delay works directly against the reported complaint, which was that the pane
took too long to go quiet.

### Round 16 — a finish you have READ is not unread (2026-07-25)

The unread agent-finish latch (`paneUnseenDone`, round 7.3) has exactly one clear path:
`clearAgentBadge`, which runs on a SELECTION change — a tab switch, a rail click, a ⌘⇧U step.
Returning to the app selects nothing. So the common shape — a turn finishes while you are in a
browser, you come back to the pane you already had focused — left the finished marker sitting on the
one pane you were staring at, and the only way to dismiss it was to click to another tab and back.
"Unread" had drifted from *you have not seen this* to *you have not re-selected this*.

The fix is a DWELL, not a clear-on-contact: a pane that is focused, in an active app, and carrying a
finished-turn marker (a live `.done` or the latch) starts a watch clock; after
`focusedDoneSettleWindow` (30 s) the client acknowledges it for you. Contact alone changes nothing —
the marker's whole job is to tell you a turn ended, and it still gets to.

Scope is deliberately narrow, and is the part worth protecting:

- **Only a focused pane in an active app.** An unfocused pane keeps the original contract exactly —
  unread until visited, however long that takes. Nothing can expire behind the user's back.
- **The window measures an UNBROKEN watch.** Focus leaving, or the app backgrounding, abandons the
  clock; a later return starts a fresh one. Two one-second glances never add up to an acknowledge.
- **Only a FINISHED turn.** `.working` and `.needsPermission` are live signals, never unread output,
  so neither starts a clock — the settle can therefore never silence a waiting approval gate.

The driver is the same one-shot idiom as the completion flash (`doneSettleScheduler`, armed when a
watch starts), because a finished agent stops mutating the store and nothing else would look again.
It gets its own property rather than sharing `flashDecayScheduler` so the two boundaries stay
independently injectable. The three edges that can change the answer — an agent-status transition, a
focus change, and the `isAppActive` edge — all call the same refresh, which both starts and retires
clocks; the acknowledge feeds back through `setAgentStatus`, by which point the pane is no longer a
candidate, so the recursion terminates on its own.

Host-side nothing changed: the status machine's own `done → idle` decay stays at 8 s. That decay
answers "what is the agent doing"; this window answers "has the user seen it" — the same split the
latch was introduced to make.

### Round 17 — the git line gets its states back (2026-07-25)

The project header's second line (`main ↑2 ↓1 +1 !3 ?5 ~2 $1`) was painted in one flat
`Slate.Text.tertiary` — the metadata register it shares with the rows' process labels and the footer
telemetry. That register is right for text that is *there if you look*; it is wrong for a line where
a merge conflict and a branch name rendered identically. The whole line sank.

Each run now carries its own ink, on two registers: a state that wants a HUMAN wears a status hue
(conflict red, dirty amber, staged green, divergence/stash info), everything else wears the readable
body ink. Nothing on the line resolves to tertiary any more — the flatness *was* the bug.

The dialect is unchanged (same sigils, same fixed order, non-zero only). `gitSegments` is now the
single source of truth and `gitLine` joins it, so the painted line, the hover tooltip and the
accessibility label cannot drift. The runs are concatenated into ONE `Text` via an `AttributedString`
rather than laid out in an `HStack`, so the line still truncates by tail — an `HStack` would clip a
whole run instead, and the run it would drop is the rightmost, which is where `~conflicts` sits.

Roles, not colours, in the pure layer (`GitInk`): the palette resolution lives in the one `@MainActor`
`ink(_:)`, so the dialect stays headlessly pinnable and a theme swap repoints every run at once.

Colour turned out not to be the whole answer, and measuring said why. Against the sidebar ground on the
default theme the runs rank `!modified` 11.9 : `↑↓`/`$` 10.3 : `+staged` 10.2 : `~conflicted` 5.7 :
branch 5.3 — the one state that genuinely needs a human pulls the eye LEAST of the coloured runs.
Monokai's yellow is bright and its red is a mid pink; no re-assignment of hues fixes that without lying
about what the states mean, and `statusErr` is theme-owned. So the line also carries a WEIGHT ladder,
which costs no palette and holds on every theme: the branch stays regular (identity, not a status),
every COUNT is semibold (at 10 pt mono a regular weight leaves the readout thin enough that colour does
all the work), and `~conflicted` is bold. The step also buys a third cue under the one CVD collapse the
measurement found — under protanopia `+staged` and `~conflicted` land ~3 ΔE apart, indistinguishable by
hue; the sigils already carried the meaning, the weight now backs them.

Measured but NOT acted on: both LIGHT themes fail AA on this line (`paper` branch 1.86:1,
`monokaiProClassicLight` every run 2.80–3.32:1). That is a theme-token defect, not a git-line one —
`paper.textSecondary` on `paper.ground` is 1.86:1 for every secondary label in the app, the folder name
directly above this line included. Fixing it repaints the whole chrome and is its own decision.

### Round 18 — Monokai Pro only, and the git line gets a ramp (2026-07-25)

The theme list shipped six Monokai Pro filters plus two one-off palettes (`paper`, `dark`) built by hand
rather than from a `MonokaiSeed`. Those two are gone. The cull is not tidying: it is what makes a
guarantee possible. Every shipped theme is now seed-built, so every theme has the SAME six chromatics —
which means chrome can reach past the status quartet and know that every filter can supply the ink.

`SlateTheme` therefore surfaces `chromaOrange` / `chromaPurple` (`Slate.Chroma`). Each Monokai filter
ships six chromatics; the status quartet spends four (green / yellow / red / cyan) and these are the
other two. They previously reached only the terminal's ANSI palette. They are deliberately NOT statuses:
no urgency attaches to them, the consumer assigns the meaning.

Which lets the git line stop sharing inks. The four WORKTREE states are a RAMP, not a set of labels:
`+staged` → `!modified` → `?untracked` → `~conflicted` is *how far this work is from being committed* —
in the index, in the worktree, git has never seen it, it is broken. The filter's chromatics sweep that
distance exactly: measured on the default theme the hue angles run 126.9° → 89.2° → 51.5° → 9.8°,
green→yellow→orange→red, monotone, in the SAME left-to-right order the sigils already appear. `?` is
orange not because a sixth colour was available but because it is the rung between "you changed it" and
"it is broken". `↑↓` divergence and `$` stash sit OFF the ramp on cool hues — neither is a worktree
state — and the branch keeps the body ink. No two runs now share an ink, which a test pins.

Measured across the six survivors: every run clears WCAG AA on all five DARK filters (min 4.89:1).
`monokaiProClassicLight` still does not (2.80–4.65:1) — unchanged and still upstream of this line, since
its own `textSecondary` and status colours are too light for its own sidebar ground.

No migration, per the standing rule: a persisted `"paper"` / `"dark"` no longer decodes as a
`ThemeChoice`, so the whole `AppearancePreferences` blob decode-fails to its all-`nil` default and the
app follows the OS onto Monokai Pro Classic / Classic Light. Nothing to write, nothing to version.

### Round 19 — the shape becomes the grammar, and two marks are allowed to move (2026-07-30)

Rounds 9–10's twin verdicts — ONE shape, hue is the whole grammar, and *nothing in the rail
animates* — are reversed BY REQUEST: the shipped rail read "tĩnh lặng và đơn điệu quá" (too still,
too samey). Four dashed rings differing only in hue is a legend you have to learn; and with motion
banned outright, a row that was *working right now* looked exactly like a row that had finished an
hour ago apart from its tint. The reference is otty's own sidebar, which spends a distinct
pictogram per state and mounts a real spinner while a command runs.

So the mark column keeps its fixed footprint and its one-mark-per-row rule, and swaps the alphabet:

| state | mark | ink |
|---|---|---|
| agent working | the breathing asterisk `· ✢ ✳ ✶ ✻ ✽` (0.15 s/frame, palindrome) — ⚠️ **superseded twice by the follow-up below; shipped as the closed turning RING** | accent |
| agent at rest | the round-8 static dashed ring — UNCHANGED | muted secondary |
| agent blocked | `hand.raised` — otty's "answer me" hand — ⚠️ **superseded: now `questionmark.circle`, see follow-up 3** | amber |
| agent done / unread finish | the filled dot (otty's `circlebadge.fill`) | green |
| failure | `exclamationmark.triangle.fill` — ⚠️ **superseded: now `exclamationmark.circle`, see follow-up 3** | red |
| plain running command | **not in this column** — see below | — |

Motion is now permitted, but under a rule narrow enough to keep the round-9 lesson: **a mark may
move only while something is genuinely in flight, and only two marks qualify.** A settled rail is
still perfectly motionless — nothing pulses to attract the eye, nothing blinks to say "unread"
(the finish is a still dot; the mail-unread weight bump on the title survives untouched).

The working pulse is not a new spinner: it reads its frames from the pulse `StatusGlyph` has
spoken on the iOS toolbar and the Peek & Reply header since MERIDIAN. The definition MOVED to
`StatusDot.pulseFrames` and `StatusGlyph` now reads from there — one breath, so the rail and a
compact header can never disagree about one pane. Frame-stepped off a fixed wall-clock epoch, so
every spinning row steps in unison and a re-render lands mid-cycle instead of restarting it.

**The running command's spinner takes the SLOT, not the mark column.** otty's `TabsPanelRowView`
mounts an `NSProgressIndicator` where the row's right-hand shell label sits, and that is the shape
of the fix: while a real command runs, the still process name (`swift`) — which looked identical
whether the command was live or had exited twenty minutes ago — yields to a drawn eight-spoke
wheel with a comet tail (0.1 s/spoke, one revolution in 0.8 s). Drawn rather than `ProgressView`
so the ink is a theme token, the footprint is pinned to the mark column's, and the phase comes off
the same epoch the pulse uses. The command line itself is unchanged in the tooltip, and the row
title still upgrades to the running command wherever it already did.

Three exclusions on that spinner, each load-bearing:

- **the busy-badge tier is the reveal gate.** No new threshold: the spinner keys on
  `commandBusy`/`commandRunning`, which `WorkspaceStore.paneShowsBusyDot` already delays by the
  "Busy reveal delay" (default 1 s), so a fast `ls` never flashes a wheel.
- **an AGENT pane never spins.** `claude` holds the shell's OSC-133 block open for its whole
  interactive lifetime, so `isBusy` stays true for HOURS — a naive "busy ⇒ spin" would leave every
  idle agent row spinning forever. This is the same trap round 14 hit from the other side (the
  muted ring belongs to the agent, not to every busy shell), and it is why the gate takes
  `isAgent` rather than reading the badge alone.
- **the shell is not a command.** A busy pane fronted by a bare login shell keeps its label, as
  does a pane whose foreground process the host has not reported: with nothing to name, there is
  nothing to claim is running.

`accessibilityReduceMotion` freezes both moving marks rather than hiding them — the pulse on `✳`
(the mid-swell frame; `·` would read as a resting dot) and the wheel on its fully-lit step. A
state that only exists as an animation would be invisible to a user who asked for stillness.

`StatusDotStyle` grows from an ink to a (shape, ink) pair; `attentionInk` is untouched and still
shared with the collapsed-group roll-up count. Client-only, no wire change, no new setting — the
existing agent/command badge gates keep governing what the row is allowed to say.

**Follow-up, same day — BOTH animated marks become drawn geometry, and no typed spinner survives in
the rail.** The AGENT's pulse read as ugly on hardware (the command wheel was never in question and
is unchanged — a misread of "the running indicator" briefly swapped it for an ASCII line sweep; that
detour is reverted). The verdict on the pulse was "drop the ASCII spinner, draw it instead so font
errors can't happen", and chasing that is what turned up WHY it looked wrong — which had nothing to
do with the design:

**The instrument face is only JetBrains Mono when that font is installed, and it is not.** It is
absent on the dev Studio, so `Slate.Typeface.instrument` falls back to the system monospaced face,
and CoreText then substitutes per-character from wherever it likes. Measured:

| frames | resolves to | advance |
|---|---|---|
| `·` U+00B7 | the system mono's own | 6.80 |
| `✢ ✶ ✻ ✽` | Menlo-Bold | 6.62 |
| **`✳` U+2733** | **AppleColorEmojiUI** | **16.00** |
| `⠋⠙⠹…` / `⣾⣽⣻…` | **AppleBraille** | — |

So the "asterisk pulse" was never one typeface: nine frames of Menlo plus one **colour emoji** at
2.4× the advance that ignores `foregroundStyle` — a coloured star that jumped the mark's width
mid-cycle, and (since the Reduce-Motion frame was `✳`) the ONLY thing a Reduce-Motion user ever saw.
Braille, tried as a replacement, is worse: **no mono face we can count on carries U+2800…U+28FF**, so
both the light `⠋⠙⠹…` and the heavy `⣾⣽⣻…` land in **AppleBraille** — an embossing font that draws
sparse little circles, ignores the requested weight, and renders the two cycles indistinguishable and
nearly invisible at 11pt. Two renders looked unchanged before the font check explained why.

Hence the first rule this round ends on: **in the mark column, animation is VECTOR, never type.**
`CommandSpinner` keeps its eight-spoke comet wheel; both animated marks step on one shared primitive,
`StatusDot.frame(at:frames:beat:)`, off the fixed epoch — so they stay in unison and pin as pure
numbers. Exact size, exact ink, no font on the machine to get in the way.

**The asterisk did not survive being drawn either, and that gave the second rule.** Redrawn faithfully
as six capsules budding out of a centre dot, the star was still judged ugly — and rendering the
candidates at true size next to a 4× blow-up showed why, in pixels rather than prose: at 12pt a
radiating star is a burr of spikes, and magnified it reads as a cogwheel. **One stroke scales down;
detail does not.**

So the working mark becomes the RESTING RING, turning: `AgentSweepMark` draws the same circle at the
same diameter and stroke weight. Which turns the agent's column into ONE CIRCLE with three readings:
**dashed while it waits at its prompt, closed and turning while it works, filled once it has finished
something you haven't read.** A progression, not a legend to learn. The choice was made from a
rendered comparison sheet of four drawn candidates (star bloom, arc sweep, travelling gap, orbiting
dot); the rig was deleted once it had done its job.

**Follow-up 3 — the circle takes the last two states, and the rotation stops being plastic.**

The two states needing a HUMAN were left outside the circle as otty's raised hand and warning
triangle. They are now **inside** it: `questionmark.circle` amber and `exclamationmark.circle` red,
drawn at the point size whose circle lands on `ringDiameter` rather than at a type-scale size — a `?`
a point wider than the ring above it breaks the family faster than any hue could. So EVERY mark in the
column is one silhouette and the INSIDE carries the state, which is the difference between a
progression and a legend: `◌` waiting · `◯` turning · `?` asking · `!` broken · `●` finished unread.
`StatusMarkShape.symbol` exposes the two circle variants precisely so a test can pin that a triangle
never creeps back.

And the rotation is now **continuous, not stepped**. Twelve discrete hops per turn read as plastic — a
hop is the mechanism showing through, and the eye reads mechanism as cheap. The angle is a smooth
function of the wall clock sampled per display frame (capped at 60 fps), and two further things move
with it, which is what separates a thinking indicator from a loading widget: the tail **dissolves**
(the stroke is an `AngularGradient`, full ink at the head to nothing at the tail, so the figure reads
as something travelling rather than a gapped shape being rotated), and the arc **breathes** (its
length oscillates across 0.45…0.78 turns on a 2.3 s sine, deliberately incommensurate with the 0.9 s
revolution, so the silhouette never repeats and the motion never reads as a loop).

Both derive from the same clock as the rotation, so the mark holds no animation STATE — which is not
an aesthetic point: a `repeatForever` animation would restart on every chrome tick and snap the arc
back to the top, and every working row would drift out of phase with its neighbours. `turns(at:)` and
`length(at:)` are pure and pinned, including that the ramp has **no plateaus** when sampled far finer
than a frame (a plateau is a hop) and that the two cycles stay incommensurate.

**Follow-up 4 — a constant rate is also plastic; the tail dot; one diameter for everything.** Three
findings from the same look, each with a mechanism behind it rather than a taste:

1. **Continuous was not enough — a CONSTANT RATE reads as mechanism too.** The angle now leads and
   lags an even sweep by `swing` = 0.055 turns twice per revolution (roughly 0.3×…1.7× rate), so the
   arc accelerates and coasts. The amplitude has an ARITHMETIC ceiling, not a stylistic one: the angle
   is `t + swing·sin(4πt)`, whose derivative is `1 + 4π·swing·cos(4πt)`, so at or above `1/4π ≈ 0.0796`
   the arc STALLS and then runs BACKWARDS once a cycle — broken, not eased. `swingCeiling` is pinned so
   a later "make it bouncier" cannot cross that line unnoticed. ⚠️ Note for whoever tests this: the
   ease crosses zero at every QUARTER turn, so a quarter-period sample sits exactly on the straight
   line and would "prove" the motion is linear; the pin samples an EIGHTH, where the lead is full.
2. **The dot trailing the arc was `lineCap: .round`.** A round cap paints a half-disc beyond each end
   of the stroke; at the tail — where the gradient has faded to nothing and the angular gradient wraps
   its seam — that cap picks up ink from the far side of the seam and shows as a DETACHED dot chasing
   the arc. Butt caps end exactly where the stroke ends, so the fade is the only thing terminating the
   tail. (At a 1.5pt stroke the now-flat head is imperceptible; verified across a full revolution and a
   full breath on a phase sheet, not on one lucky snapshot.)
3. **One diameter, no exceptions.** The finish dot was drawn at 6pt against the ring's 8pt, on the
   reasoning that a solid mark carries more weight per point than an outline one. True in the abstract
   and wrong here: it made the column's sizes wobble row to row, which is the one thing a fixed status
   column may not do. `dotDiameter` is now an ALIAS of `ringDiameter` so it cannot drift again, and the
   `?`/`!` point size is chosen by where its circle lands (≈0.8× the point size) rather than by type
   scale. All four pinned.

**Follow-up 5 — the working ring is DASHED, and the whole gradient idea was the problem (user's
proposal).** The eased comet arc was still rejected, and the suggestion that replaced it — *"để ring
là các nét đứt rồi xoay xoay có đẹp và độc đáo hơn nét liền không"* — is right, for a reason the
render sheet makes plain rather than a stylistic one. Six cuts were drawn at true size and at 8×:

- ⚠️ **At 12pt, a gradient spends half its length being invisible.** That is what a comet IS — full ink
  at the head, nothing at the tail — and it is why the arc looked good magnified and generic-to-muddy
  at the size it actually ships. Every gradient cut on the sheet lost its faded half at 1×. The rule
  that now covers this column: **flat ink and whole shapes at 12pt; gradients and detail are luxuries
  of the zoomed-in view.** (Same shape as the round-19 lesson "one stroke scales down, detail does
  not" — a third instance, so it is written as a rule now.)
- ✅ **Dashes carry motion that a comet cannot at this size**: several small shapes crossing the ring
  are legible even though each is barely 2pt long, and no single one has to fade to say "moving". It is
  also not the arc-spinner every platform already ships, which is what "generic" meant.
- ✅ **The cut is FIVE dashes, not the resting ring's eight.** Eight at 8pt reads as a nearly solid ring
  (measured — the dashes stop separating), and identical dashes would have made the working mark the
  resting mark in a different hue the moment Reduce Motion froze it. Five longer arcs is the same
  circle carrying MORE INK while it works — a progression — and stays legible frozen and to a
  colour-blind eye. Pinned: `dashCount` < `ringDashCount`, and each working arc longer than a resting
  dash.
- ✅ **The surge is per DASH, not per revolution.** What the eye tracks is one arc crossing into the
  next slot, so the ease rides `sin(2πN·t)` and the stall ceiling TIGHTENS to `1/2πN` (0.0318 at five
  dashes, vs `1/4π` for the one-per-half-turn cut) — `swing` = 0.020 gives 0.37×…1.63×. A surge per
  revolution would read as a wobble with no visible cause. ⚠️ Test trap moves with it: the ease now
  crosses zero every HALF dash period, so the "not linear" pin samples a QUARTER of one.
- ✅ **Revolution is 3.6 s, read through the dashes**: one arc reaches the next slot in ~0.7 s. Spinning
  the RING at that rate would strobe — with rotational symmetry every 1/5 turn, a 1 s revolution is
  five visual cycles a second.
- ✅ **The breath moved from the arc's LENGTH to the dashes' FILL** (0.5…0.7 of each period, still on the
  incommensurate 2.3 s cycle): the arcs lengthen and shorten as they travel. Above ~0.75 the ring is
  solid with notches in it; at 0.5 ink and gap are exactly even, and that is the floor. Pinned that the
  dashes tile the circumference exactly at EVERY breath frame — a breath may not open a seam.
- ✅ **Two problems deleted rather than fixed:** a dashed ring has no ends to cap (so no round-cap tail
  dot, follow-up 4 №2) and no gradient seam to cross. `AngularGradient` and `lineCap` are gone from
  this mark entirely.

**Follow-up 6 — the glyphs come OUT of the two human states, and the arcs learn to split and knit
(both user calls).** Two changes, and the second is why the first is affordable:

- ✅ **`?` and `!` are gone from inside the ring** — *"bỏ 2 cái symbol ở trong ring của block và error
  đi"*. Those two states now draw the ring **CLOSED and still**, on amber and red. That completes a
  ladder the column had been circling for six follow-ups: the mark's **COMPLETENESS rises with how
  much the row wants from you** — fine dashes at rest → five turning arcs at work → CLOSED when it
  wants a human → FILLED when it has finished something unread. Third cut of these two states to be
  pulled (hand/triangle → `?`/`!` → nothing), each time for the same reason: detail does not survive
  8pt.
- ⚠️ **The cost, stated plainly: blocked vs failed is now HUE-ONLY.** `question` and `alert` remain
  distinct enum cases but draw identically, so amber-vs-red is the whole difference in that column —
  the exact thing round 19 set out to stop doing. It is a deliberate user ruling, pinned as such
  (`testTheColumnIsFiveDrawnShapesAndNoGlyphs` asserts the two inks can never collapse together), and
  it is survivable only because the row's title, tooltip and VoiceOver value still name the state in
  words. `symbolSize` and `StatusMarkShape.symbol` are deleted — the column now has NO glyph at all.
- ✅ **The working arcs SPLIT and KNIT** — *"thêm hiệu ứng các dash tách nhỏ hơn, rồi định kì gộp
  lại"*. Each of the five arcs parts down its middle into two, the ring travels a while as ten, and
  the halves close back into five, on a 2.9 s cycle incommensurate with the 3.6 s revolution. This
  REPLACES the fill breath: three oscillations on an 8pt mark is mush, and this one is visible where
  the breath was subliminal.
- ✅ **The parting is ONE continuous parameter, not a swap between two dash patterns.** The dash array
  is `[half, parting, half, gap]`, and at rest the parting is a **zero-length gap** — so the halves
  abut and render as exactly the arc they came from. A pattern swap would pop; this cannot. Pinned that
  the four elements still tile the circumference exactly at every parting (a split may not open a seam).
- ✅ **Eased at BOTH ends (smoothstep of a raised cosine), so it DWELLS as five and dwells as ten** and
  crosses quickly between. A plain sine spends its time mid-parting and reads as a wobble rather than
  two states trading. Pinned by the dwell (a tenth of a cycle from an extreme stays within a tenth of
  it) and by the crossing rate beating a raw cosine's.
- ⚠️ **`splitMax` = 0.26 is a legibility ceiling, walked on a render sheet rather than guessed**: at
  0.16 the pairing is clean, 0.26 is the most parted the halves stay visibly PAIRED at, and by 0.45 the
  ring is ten thin specks. The upper bound matters twice — past it each half is a speck at 8pt, AND ten
  evenly-spaced short dashes IS the resting ring's cut, which the working mark may not borrow. Reduce
  Motion therefore freezes it fully KNIT (five long arcs), the frame furthest from the resting ring.

**Follow-up 7 — split-and-knit is OUT: one mark, one idea.** *"nhìn cái trò chia ra hơi quê"*. The
parting worked exactly as specified — continuous, eased, seam-free, bounded — and still read as a
gimmick, which is the useful part of the finding: **at 12pt a mark can carry ONE idea, and "turning" is
the one that means "working".** Every second rhythm tried on this mark has now failed the same way (the
arc-length breath was subliminal, the parting was corny), so the ring is a fixed dash pattern with a
single eased rotation, and `dashFill` is a constant rather than a function of time.

⚠️ Kept for the next round rather than argued in prose: a **motion study rig** renders nine candidate
dash-ring motions (turn, chase, runner, pendulum, wave, gyro, breathe, conveyor, inchworm) as a frame
sequence → animated GIF, because four cuts of this mark have now been rejected on MOTION, which no
still can settle. The lesson those four share: judge a 12pt animated mark by watching it at 12pt, not
by reasoning about it magnified.

**Follow-up 8 — the fifth cut: the ring stops moving, and the LIGHT travels instead ("chase").** The
nine-motion study was watched as a GIF and cut 2 was picked. Shipped as `AgentWorkingMark` (renamed from
`AgentSweepMark`, and `StatusMarkShape.sweep` → `.working` — named for the STATE, because the motion has
now been recut five times and the type should not be renamed a sixth):

- ✅ **Nothing moves geometrically.** Five arcs sit at fixed angles for the mark's whole life; a gaussian
  pulse of BRIGHTNESS travels round them, each arc handing the light to its neighbour (lap 1.2 s ⇒ an arc
  lights every 0.24 s). Pinned by the API's own shape: `start(arc:)` takes an index and no instant, so
  there is nothing to move the geometry with.
- ✅ **This is the closest the rail gets to round 9's original verdict** (*nothing in the rail animates*)
  while still saying "in flight": the figure's silhouette is as still as the resting ring's, and it does
  not read as any platform's loading spinner, because a spinner is a shape going round.
- ⚠️ **`dimFloor` = 0.28, not zero.** The comet cut already proved that ink fading to nothing at 12pt
  simply disappears — a floor of zero would break the ring into a moving arc, i.e. back to the generic
  spinner. The floor is what holds the SHAPE constant while only the light moves. Pinned both ways
  (below ~0.15 the dim arcs vanish; above ~0.5 the light stops reading as a light).
- ⚠️ **The falloff distance is WRAPPED** (measured the short way round). Unwrapped, the chase stalls and
  jumps at 3 o'clock once per lap, where the seam is — pinned by asserting the two sides of the seam
  light arc 0 identically.
- ⚠️ **Reduce Motion parks the light ON an arc, not at 12 o'clock.** With five arcs nothing sits exactly
  at the top, and a light frozen in a GAP is the one still frame that reads as broken: two half-lit arcs
  and no subject. `stillPhase` is computed as the middle of the arc nearest the top, so it stays on an
  arc if the count ever changes. (Both of these were found BY the pins, not by eye.)
- ✅ **Linear travel, deliberately** — the opposite call from the turning cut, where a constant rate was
  the tell. A light has no mass, so easing it would be the mechanism showing rather than hidden.

**Follow-up 8a — the cut is now the resting ring's, ALIASED** (*"để dash ngắn hơn, giống idle
indicator được không?"*). The working ring had been five longer arcs on the argument that "more ink =
more happening"; it made the column's rhythm change from row to row for no gain, and the light says
"happening" better than extra ink ever did. So `dashCount`/`dashFill` are now aliases of
`StatusDot.ringDashCount`/`ringDashFill` — shared at the source, not merely equal today — and working
vs resting is **hue + one travelling light**, nothing else.

Two consequences worth writing down, both pinned:

- ⚠️ **Frozen legibility moves from the CUT to the LIGHT.** The old safety was "five long arcs are not
  eight short ones"; with the cut shared, Reduce Motion would collapse the two marks to one shape in two
  hues — except that the parked light is itself the difference: exactly ONE dash at full ink against
  neighbours at `dimFloor`, in the accent. Pinned as a contrast floor (>0.5) and as "exactly one dash
  above the midpoint", because a frozen frame with two equal candidates has no subject.
- ⚠️ **The HAND-OFF is the constant; the lap is DERIVED.** What the eye times is one dash lighting the
  next (0.24 s), not the lap — so `lap = handoff × dashCount` and `pulseWidth = 0.7 × slot`. Going from
  five dashes to eight under a fixed lap would have flickered 1.6× faster and strobed; a cut with more
  dashes must take LONGER to go round. Pinning the lap instead of the hand-off is exactly how a
  dash-count change turns into a strobe nobody meant.

Rejected on the sheet, each for a stated reason rather than taste: **runner** (the discrete cut of chase
— a hop is what "plastic" meant), **conveyor** (a comet in disguise: half the ring fades to 0.12 and
disappears at 8pt), **gyro** (two rings fill the gaps at 8pt, so the dashes stop being dashes). Held in
reserve: **wave** (arc lengths ripple, positions fixed — the same "geometry still, content alive" idea
expressed in SHAPE rather than ink, and so immune to the dim-arc risk if `dimFloor` turns out too faint
on real glass) and **inchworm**.

**Follow-up 9 — the SIXTH cut, and it is nearly the third: a solid arc that CHASES ITS OWN TAIL**
(*"để thành nét liền xoay vòng quanh đi, làm spinner xoay mượt, giữ nguyên đuổi, xoay đầu đến 1 mốc rồi
thu đuôi lại quay tiếp"*). Material's indeterminate circular indicator, drawn on the house tokens: through
the first half of a 1.4 s cycle the HEAD runs out to a `span` of 0.75 turn; through the second the TAIL
catches up to it; the figure drifts the remaining 0.25 turn so it advances **exactly one turn per cycle**.

⚠️ **The distinction from cut 3 is the whole lesson, and it is why this is not a circle back to a rejected
design.** Cut 3 was also a solid arc — but its tail DISSOLVED through an `AngularGradient`, and what
failed was the gradient, not the arc: at 12pt a fade spends half its length invisible, so the figure read
as a shrinking smudge and needed an argument about `lineCap` bleeding ink across the gradient's seam. This
cut is FLAT INK with two hard ends, where the "tail" is a real geometric end that MOVES. Which also makes
**round caps safe again** — no gradient means no seam for a cap to pick ink up across — and round ends are
what make a spinner look drawn rather than cut.

- ✅ **Seamless by construction, so the mark still holds no animation state**: at a cycle's end head and
  tail have both travelled exactly `span`, which is precisely where the next cycle begins. Pinned across
  the boundary, plus tail-monotonic over 2,000 samples: a discontinuity here is a visible jump every
  1.4 s, which is exactly what a `repeatForever` animation produces on every chrome tick.
- ✅ **`span + spin == 1` exactly** — not arithmetic tidiness: it means the head lands on the same clock
  position every cycle, which is what stops a spinner from looking like it is wandering.
- ⚠️ **`minSweep` = 0.07 turn (~25°), never zero.** An arc allowed to collapse to nothing BLINKS OUT at
  the end of every cycle, and a mark that vanishes 40 times a minute reads as broken rather than busy.
- ✅ **The head EASES onto its mark** (smoothstep, pinned as a rate ratio between the middle and the
  ends). The constant-rate finding from the turning cut is kept, not relitigated.
- ✅ **Frozen legibility goes back to SHAPE.** Reduce Motion parks the widest arc; a continuous
  three-quarter arc cannot be mistaken for the resting ring's eight dashes, so the guarantee no longer
  leans on a parked light's contrast the way cut 5's did.

The rail's motion budget is unchanged by all six recuts: **two marks may move, only while something is in
flight** (this arc, and a command's slot wheel), and nothing blinks to say "unread".

The typed twin that survives is `StatusGlyph` (iOS toolbar, Peek & Reply header): 16pt in a text row,
where the glyph is the right primitive. Its frames now carry `\u{FE0E}` (variation selector-15, text
presentation) — the same guard `SlateTabRow` already applies to the title's `✳` marker — which fixes
the colour-emoji frame those two surfaces have shipped since MERIDIAN. It shares the BEAT with the
drawn mark and nothing else; one constant is not worth a font dependency at 11pt.

### Round 20 — round 19 is REVERTED whole: the rail goes back to static marks (2026-07-30)

*"Thôi, quay về các indicator tĩnh như ngày xưa đi cho tôi, lúc mà command vẫn chỉ hiện tên command
đang chạy, các indicator tĩnh ấy."* Rounds 9–10 are reinstated exactly: **ONE shape — the static dashed
ring — the HUE names the state, a running command shows only its NAME in the slot, and nothing in the
rail animates.** `AgentWorkingMark`, `CommandSpinner`, `StatusMarkShape`, `RailRowsBuilder`'s spinner
gate and `SlateTabRow.commandRunning` are all gone; `StatusDotStyle` is one `ink` again.

⚠️ **The whole of round 19 above is kept in this file on purpose, because it is a rejection history, and
it is the second time the rail has arrived at the same verdict from opposite directions.** Round 9 banned
motion by argument; round 19 spent a day of iterations proving it by exhaustion — SIX cuts of one 12pt
mark, every one rejected on looks:

| cut | what it was | why it died |
|---|---|---|
| 1 | asterisk bloom, TYPED | the mono face has no star ⇒ `AppleColorEmojiUI` drew a colour emoji at 2.4× the advance |
| 2 | the same bloom, DRAWN as capsules | at 12pt a radiating star is a burr of spikes; magnified, a cogwheel |
| 3 | solid arc, comet tail (`AngularGradient`) | a gradient at 12pt spends half its length invisible |
| 4 | dashed ring turning, arcs splitting into ten and knitting back | the split read as a gimmick; a turning ring is still a spinner |
| 5 | dashed ring standing still, a LIGHT running through the dashes | calmest of the six, still not it |
| 6 | solid arc chasing its own tail (Material's indeterminate) | "quay về các indicator tĩnh" |

**What survives the revert, and why each one is worth keeping:**

- ✅ **The `\u{FE0E}` fix in `StatusGlyph`** — a REAL pre-existing bug, unrelated to the rail question:
  bare U+2733 `✳` resolves to `AppleColorEmojiUI`, a colour emoji that ignores the tint and measures
  16pt of advance where its Menlo siblings measure 6.62. The iOS toolbar and the Peek & Reply header had
  been flashing a coloured star at the wrong width since MERIDIAN. Kept, and pinned.
- ✅ **The rule that a 12pt mark is judged at 12pt, by WATCHING it.** Every cut above looked defensible
  magnified and cheap at size; the render sheets and the frame-sequence GIFs (`ffmpeg` out of an
  `ImageRenderer` rig) are what settled each round, not prose. Cheap to rebuild, so the technique is
  written down rather than the rigs kept.
- ✅ **The design rules the six cuts bought**, all of which now apply to whatever comes next here: at
  12pt use FLAT INK and WHOLE SHAPES (gradients and detail are luxuries of the zoomed-in view); a mark
  this size carries exactly ONE idea; motion in a status column must mean "in flight" or not exist.
- ⚠️ **`StatusDot.footprint` goes back to 10pt** (round 19 widened it to 12 for the spinner). Anything
  re-added to this column must fit 10.
- ❌ **Not kept, deliberately:** the otty pictogram vocabulary (raised hand, warning triangle, `?`/`!`
  glyphs, the filled finish dot). Every one of them was pulled during round 19 itself for reading as
  fussy detail at this size, so the revert loses nothing that survived its own round.

**Follow-up — one shape distinction survives after all: the unread FINISH closes the ring** (*"để done
indicator là nét liền cho tôi đi"*). Every open state keeps the dashed circle — working, resting, waiting
on a human, failed — and the finish draws it as one continuous stroke. It earns the exception that the
otty pictograms did not:

- ✅ **It needs no legend.** "Broken = still open, whole = it ended" is readable the first time it is
  seen, where a raised hand or a `!` has to be learned.
- ✅ **It survives 8pt**, which is what killed every previous shape distinction: there is no detail in
  it — the same circle, the same diameter, the same stroke weight, with the dash pattern withheld. The
  implementation is literally the one draw call with `dash: []`, so there is no second code path to
  drift out of alignment with the dashed one.
- ✅ **Both finish tiers close it** (`.completed` flash and settled `.finished`), because that split is
  semantic — freshness machinery and control-backend badge tokens — and has never been visual.
- ⚠️ **Pinned as the ONLY shape distinction the column carries**, with the rounds-19–20 history cited at
  the pin, so "while we are at it, the error could be a triangle" has to argue with the ledger first.

### Round 24 — a command's outcome is a WORD, not a mark (2026-07-31)

The user pulled the command-outcome indicator outright: drop the mark, and let the text at the row's
trailing edge carry the exit instead — a clean one in the git line's own register (bold, text
foreground), a non-zero one in red. Round 21's two speakers survive with one of them moved off the
mark column: the ring/check/hand/spinner column is now the AGENT's alone, and a COMMAND's exit is the
trailing slot's text, reading the command's own name (`make`, `swift`, `deploy.sh`).

- ✅ **A mark could not name the command; a word does both jobs at once.** The disc said "something
  you didn't watch has ended" and the triangle "something broke", and in both cases the reader's next
  question was *what*. Round 23's own decision to EMPTY the slot beside the mark (`d3e68936`) is what
  made this obvious: the row was already giving up its only naming space to keep a glyph that named
  nothing. `make` in red is one glance, and it is strictly more information than the triangle was.
- ✅ **The register is the git line's** (round 17 → `1b289043`), not a new one: the same instrument
  mono at the same caption size the resting process label uses, stepped up to the primary ink and
  BOLD. Only the register changes between "what is running here" and "what just finished here", so
  the slot never becomes a second alphabet — and a settled rail still reads as one column of text.
- ⚠️ **Red is the only hue spent, and success gets NONE.** Green was tried as the disc's ink and is
  not worth carrying over: a clean exit is the expected outcome, and hue spent on the expected leaves
  nothing for the exception. Brightness + weight carries "this row did something"; red carries
  "and it broke" — the same two-register answer the git counts settled on.
- ⚠️⚠️ **A badge now has exactly ONE voice, and that is pinned.** `StatusPresentation.mark(for:)`
  returns `nil` for the command tiers and `commandOutcome(badge:agentFinish:)` returns `nil` for
  everything the mark speaks for; `testEveryBadgeHasExactlyOneVoice` walks all nine kinds × both
  finish owners asserting they never both fire. Without that pin the obvious "restore the dot too"
  edit reads as additive and lands as the same news twice in two dialects.
- ⚠️ **The failed block's attribution moved into the builder** (`RailRowsBuilder.failedBlock`) because
  a SECOND consumer now needs it. The gate is unchanged and still load-bearing: `.error` is reachable
  from a live `OSC 9;4;2` whose block is still OPEN, so `blocks.last(where: \.isFailed)` would name an
  older, unrelated command. Unattributed failures fall back to the foreground process — red without a
  culprit beats red with the wrong one.
- ⚠️ **The name is the command's FIRST real word, basenamed**, with a leading `sudo` and leading
  `KEY=value` env assignments skipped. The slot is one narrow column beside a title that must
  truncate last, so arguments stay in the tooltip; `sudo` in particular would restate the privilege
  badge two glyphs away.
- ✅ **`StatusMark.commandFinish` / `.failure` are DELETED, not left unreachable**, along with
  `dotDiameter` and `markSpeaksForTheSlot`. A dead case in this enum is an invitation to re-mount it.
- ✅ **Judged by rendering.** `testRenderTabRowBadges` now carries both receipts, so the red word and
  the bold word are checked at true size next to the agent marks that stayed.

### Round 23 — the marks are otty's, TRANSCRIBED not approximated (2026-07-30)

The user reversed the abstract-geometry line: otty's badge symbols are more elegant than our
ring/ring/dot, so follow them — but draw them PROPERLY this time, because the earlier attempt to
follow them produced symbols that were not otty's and looked bad. The rail's mark column now speaks
otty's `TabBadge` vocabulary, case for case, read out of the shipping app rather than guessed:

| otty `TabBadge` | what otty draws | ours |
|---|---|---|
| `running` (tag 0) | a spinning `NSProgressIndicator`, **14×14**, 8pt in from the row's trailing edge | agent working |
| `completed` (tag 1) | `checkmark.circle.fill`, 12pt `NSFontWeightMedium`, `ottySuccess` | the AGENT's turn ended |
| `finished` (tag 2) | a plain filled **8pt** oval | a background COMMAND's clean exit — *dropped in round 24; the slot names it instead* |
| `error` (tag 3) | `exclamationmark.triangle.fill`, 11pt Medium, `ottyDanger` | a failure — *dropped in round 24; the slot names it in red* |
| `caffeinate` (tag 4) | a Material duotone cup (`PrivilegeIconSVG.caffeinate`, an embedded `<svg>`) | caffeinate — replaces our `∞` |
| `awaitingInput` (tag 5) | lucide `hand` (`AgentRegistry.awaitingInputIcon`, an embedded `<svg>`), 14×14, `ottyWarning` | a question waiting |
| `sudo` (tag 6) | `shield.fill`, 11pt Medium | sudo — replaces our `#` |

Plus ONE mark that is ours, because otty has no need for it: an agent that is merely PRESENT takes
lucide `circle-dashed`, muted. otty draws nothing there; our rail needs it, because `claude` sitting
at its prompt is otherwise indistinguishable from a shell that has been busy for an hour.

- ⚠️⚠️ **"Follow otty" failed last time because we redrew otty's icons by eye.** Two of them are not
  system symbols at all — they are literal SVG path data compiled into the app — so the nearest
  look-alike is a different icon, not a rounding error. The fix is a path-data reader
  (`SVGPath`, `VectorIcon.swift`) and the `d` strings kept VERBATIM in `OttyIcon`. The ones that ARE
  system symbols are mounted with `Image(systemName:)` at otty's own point size and weight, which
  makes them Apple's artwork exactly rather than a copy of it.
- ⚠️⚠️ **The other half of "it looked bad" was the SIZE.** otty lays every badge out in a 14×14 box;
  rounds 19–21 squeezed the same silhouettes into an 8pt column and pulled them for reading as fussy
  detail. `StatusDot.footprint` is now 14 — otty's box, undivided — and the ring grew 8 → 10 to sit
  with a 12pt filled check. The "three marks is the ceiling" pin from round 21 is SUPERSEDED: the
  ceiling was a symptom of the column being too small for a silhouette to survive in.
- ⚠️⚠️ **The working mark is the PLATFORM's indeterminate indicator, not a shape of ours.** That is
  what otty shows for `running`, and it is what this rail shows now. Round 19's hand-rolled
  `SpokeSpinner` and round 22's radial pump and this round's first attempt (a shimmer sweeping the
  ring's dashes) are all gone: they were inventions where the app being copied simply uses the
  system spinner. Nothing about it is ours to tune — no ink, no cadence, no frozen frame — and
  Reduce Motion becomes the platform's call, which is correct for the platform's own control.
- ✅ **Round 21's two speakers turn out to be otty's split as well**, drawn the same way: the AGENT's
  finish is the check, a background command's clean exit is the plain disc. The reason is unchanged —
  an agent's state is continuous and survives being looked at, while a command badge is an unread
  receipt the store keeps only for an UNFOCUSED pane and drops on focus. (Our `.completed` /
  `.finished` split stays semantic — freshness machinery — and both resolve to the same mark.)
- ✅ **Everything round 22 decided still holds**: motion instead of hue, and the gate on RAW
  `.working` — never `isBusy`, because `claude` holds the OSC-133 block open for its whole lifetime,
  so busy-means-motion would move every idle agent's row for hours. Exactly one mark moves.
- ⚠️ **The path reader's one real trap: an arc's two flags are ONE CHARACTER each.** Minified data may
  pack them against the coordinate that follows (`a2 2 0 014 0`), and a number-shaped read swallows the
  lot — silently, yielding a path, just the wrong one. Pinned by `VectorIconTests`.
- ⚠️ **Material duotone fills need EVEN-ODD.** The cup punches its inner wall with a second subpath
  wound the same way as the outer one; non-zero winding fills the hole in solid.
- ✅ **The generating row's TITLE shimmers too** — a highlight band sweeping across its own glyphs,
  keyed on the SAME raw-working input the spinner is, so the two can never disagree about which row
  is alive. The spinner says it in the mark column; the shimmer says it where the eye already is,
  which is what matters on a rail running several agents at once. It is a MASK, not a recolour: the
  glyphs keep their shape, weight and ink, and no layout moves. ⚠️ Its floor was set from a render —
  at 0.55 the unlit title sat BELOW the resting rows' secondary ink, so for most of every pass the
  row doing the work read dimmer than the ones asleep. Reduce Motion simply drops it, and that costs
  nothing: it is the second voice on a fact the mark already states.
- ⚠️ **The crest is held BACK from the band's leading edge** (0.3 of the band, not centred). The band
  travels head-first, so with a centred crest the first thing the glyphs ever show is the peak
  itself, arriving at full strength the instant it crosses the head — it reads as the highlight being
  switched on AT the left edge rather than sliding out from behind it. Held back, a long ramp enters
  ahead of the peak and the light creeps out of the corner.
- ⚠️⚠️ **The band must stay well UNDER the run's width.** Shipped first at 0.45 with a 60pt floor,
  which on the rail's real titles — a project name, a bare `api` — covered the run end to end: the
  title blinked on and off instead of being swept, and the wrap read as a jerk back to the head
  rather than as a band leaving. Now 0.35 with a 16pt floor, and the render carries a SHORT title
  precisely because that is where the defect lives.
- ⚠️⚠️ **The pass's two endpoints must DIFFER.** Wrapping the phase (`phase - phase.rounded(.down)`,
  tried once so a mid-pass restart would be seamless) makes `offset(0) == offset(1)` — and SwiftUI
  animates the RESULTING offset between a transaction's endpoints, it does not sample the function
  over time. The interpolation becomes a no-op and the shimmer silently stops existing. It compiled,
  it passed every pinned-phase render (those set the phase by hand), and it shipped to hardware
  before anyone saw it was gone. `Slate.Shimmer.offset(phase:runWidth:)` is now a pure function with
  `testThePassActuallyTravels` pinning that it is monotonic and that its ends differ — the class of
  bug a snapshot harness is structurally blind to.
- ⚠️ **A layer render photographs an animation's MODEL value**, so a live capture of a shimmering row
  yields the same frame every time. `SlateTabRow.shimmerPhase` exists for that: the filmstrip and GIF
  draw the SHIPPING row at pinned instants rather than a mock of it.
- ✅ **A command's OUTCOME empties the slot beside it.** The disc or the triangle is the row's whole
  news; `make` / `swift` printed next to it is what WAS running, past tense, on a row whose title
  already says it — two words where one was doing the work. Everything still LIVE keeps its label,
  because a running command's name is current information (`markSpeaksForTheSlot`).
  **SUPERSEDED by round 24**: giving up the slot to keep a glyph that names nothing was the tell —
  the outcome IS the word now, and the marks (and `markSpeaksForTheSlot`) are gone.
- ⚠️⚠️ **The spinner's APPEARANCE has to be set on the control.** `ProgressView` came out dark grey
  on a dark theme, and neither obvious fix moved it: `\.colorScheme` in the environment is SwiftUI's
  own notion, and the WINDOW's `NSAppearance` is pinned by `SlopDeskSplitViewController` but
  `.preferredColorScheme` does not cross into the column `NSHostingController`s (SlateDesign's
  header says so for the tokens; it is just as true for system controls). Shipped as an
  `NSViewRepresentable` over `NSProgressIndicator` with `appearance` set directly — which is the
  class otty uses anyway. Measured after the fix: the fins land on the SAME grey as the rail's
  muted marks, which is the register they belong in.
- ⚠️⚠️ **`ImageRenderer` CANNOT rasterize the spinner** — it silently substitutes the yellow
  unavailable-placeholder tile for any AppKit-backed view. `SlateSnapshotRender.renderHosted` hosts
  the view in a real offscreen `NSWindow` and draws its layer instead. Three details are load-bearing
  and each one cost a wrong render: the WINDOW is not optional (an `NSProgressIndicator` outside one
  never starts animating); the window's appearance must be pinned from the theme or the capture lies
  about every system control; and the layer tree's `contentsScale` must be raised before
  `CALayer.render(in:)`, which replays cached contents and otherwise photographs 1× tiles. A system
  SYMBOL additionally has to be re-drawn at the larger point size to magnify — `Image(systemName:)`
  rasterizes at its point size, so a `scaleEffect` tile is a blown-up 12pt bitmap. `StatusMark`
  exposes `systemSymbol` so the shipping view and the magnified tile read one source.
- ✅ **Judged by rendering.** `testRenderStatusMarks` writes the whole vocabulary at true size and 8×.
  A mistyped coordinate parses happily and is invisible in the values.

⚠️ **How the symbols were measured**, so the next round does not guess:
`nm -a … | swift demangle | grep -i badge` finds `TabsPanelRowView.cached*Badge`; `otool -tV -p
'…TabsPanelRowViewC4draw…Tf4dn_n'` shows each `imageWithSystemSymbolName:` beside its
`configurationWithPointSize:weight:`. Names of 15 characters or fewer are NOT in the literal pool —
they are small strings built by `mov`/`movk`, little-endian ASCII (`0x662e646c65696873` = `shield.f`).
`strings -a … | grep '<svg>'` yields the 20 embedded icons. Case names come out of
`__TEXT,__swift5_reflstr`. Tints are `NSColor.ottySuccess` / `ottyWarning` / `ottyDanger` off
`UiThemeJson.semanticCache` — the same green/amber/red budget the rail already spends.

### Round 22 — thinking is the one thing in the present tense, so it MOVES (2026-07-30)

The user proposed the thinking indicator directly: keep the mark on the TEXT colour and change no hue
at all, and let the dash chunks slide outward from the ring and back in one after another, the way an
EDM visualizer's bars run around a circle. The mark for a WORKING agent is now exactly that — the same
dashed ring with a crest travelling around it, on the row title's own primary ink.
Round 19's blanket "nothing in the rail animates" is narrowed, NOT reversed — see the gate below.

- ✅ **Motion instead of hue, and both halves are wins.** Thinking is the only state on this rail
  happening in the present tense, and motion is the one thing a static mark cannot forge (the accent
  ring said "working" the same way an hour-old finish said "finished" — a legend you have to learn).
  Handing the state to movement also hands its ACCENT BACK to the hue budget, so colour on this rail
  now means only what wants the eye: amber question, green finish, red failure.
- ✅ **The trough IS the resting ring** — same 8pt diameter, same lucide `circle-dashed` cut, same
  weight — and the wave only ever pushes OUTWARD from it. So the pumping mark is visibly the same
  alphabet, not a new pictogram: three marks is still the ceiling (round 21), and `pulsing` is a flag
  on the open ring rather than a fourth case.
- ⚠️ **The gate is `.working` RAW, and that is load-bearing.** `claude` holds the shell's OSC-133 block
  open for its whole interactive lifetime, so an `isBusy`-keyed rule leaves every idle agent's row
  moving for HOURS — the exact failure that got round 19 reverted. Nothing settled pumps, pinned by
  `testNothingSettledPumps`.
- ⚠️ **Footprint 10 → 12.** The column is sized by the widest thing it draws, and at full crest that is
  `4 + 1.25 + 0.75 = 6`. Every settled mark keeps its own size and simply gets more air.
- ❌ **Rejected: shrinking the ring to fit the excursion inside 10pt** (base `6.5pt`, so the crest
  grazes the old edge). Rendered: at r=3.25 the gaps fall UNDER the stroke width and the eight
  segments fuse into a notched blob. The dash rhythm is the mark's identity — spending it to save 2pt
  of column buys a different, worse mark.
- ⚠️ **`addArc` is a trap in this shape, in both spellings** — found by rendering, not by reading. With
  no current point it sweeps the 333° COMPLEMENT (eight near-complete rings at eight radii = one fat
  blob); seeded with a `move`, CoreGraphics recomputes the arc start an ulp off it and leaves a
  hairline connector at a ~180° corner, which mitres into a 10×-lineWidth SPIKE out of the mark, rounds
  into a fat pill on every lifted segment, and bevels into a visible notch. The segments are polylines
  (8 chords, 0.002pt off the true arc) precisely so there is no seam to dress.
- ✅ **Reduce Motion FREEZES on a crest** rather than dropping the mark — a state that exists only as an
  animation is invisible to someone who asked for stillness — and the thinking ink is PRIMARY against
  the resting ring's SECONDARY, so the two never collapse into one mark when held still.
- ✅ **Judged by watching it, per round 20's rule.** `SlateSnapshotRender.testRenderThinkingRing` writes
  BOTH a phase filmstrip (true size + 8×) and an animated GIF at the shipped 1.4s period. A still frame
  is not sufficient evidence for this mark, and the three geometry bugs above were all invisible in the
  values — only the render showed them.

### Round 21 — the column has TWO speakers: the ring is the agent's, the dot is a command's (2026-07-30)

*"Status của command thường cần khác với agent, ở trạng thái complete và error."* Correct, and the rail
could not say it: `TabBadgeResolver` FUSES an agent turn ending and a background command's clean exit
into the same `.completed`/`.finished`, so a finished agent and a finished `make` drew the identical
green ring. Three facts decided the shape of the fix:

1. **`.error` was already command-only.** `ClaudeStatus` has no error case — red can only come from a
   non-zero exit or a held-red `OSC 9;4;2`. The rail was spending the agent's mark on a command's fact.
2. **A command badge is an EVENT, not a state.** `BackgroundCompletionPolicy` records it ONLY for an
   UNFOCUSED pane (failures always, clean exits only past the ~10s long-running floor, so `ls` never
   greens the rail) and `clearActiveLeafCompletionBadge` deletes it the instant the pane is visited.
3. **An agent's state is CONTINUOUS** — working, resting, blocked, done — and survives being looked at.

So the geometry names the SPEAKER and the hue keeps naming the STATE:

| | mark | states |
|---|---|---|
| **agent** (a living session) | the dashed RING, closed when its turn ended | accent working · muted resting · amber question · green finish |
| **command** (an outcome) | a small filled DOT | green clean background finish · red failure |

- ✅ **The split is the data's own, not decoration.** Ring = something is (or was) alive here; dot =
  something happened here while you were away. That is exactly the state/event line the store already
  draws, so nothing has to be learned that the rail is not already doing.
- ✅ **It costs the hue budget nothing** — a command's green is the same green — so the column keeps ONE
  palette and adding the second alphabet did not add a colour.
- ✅ **One envelope, one column.** The dot is `5pt` inside the ring's `6.5pt` aperture, both centred in
  the same 10pt footprint, so the right edge cannot widen depending on which mark a row draws. Diameter
  picked by RENDERING 3–6pt beside the ring at true size (round 20's technique): below 4 it reads as a
  stray pixel, at 6 it weighs as much as the ring it must stay quieter than.
- ✅ **The dot is deliberately the LIGHTER mark.** A finished `make` must not outshout a live agent.
- ⚠️ **ONE predicate owns "whose finish is this"** — `RailRowsBuilder.finishIsAgents` (a live `.done` or
  the client's unread latch, and only on a finish badge). It already existed as the gate for the row's
  agent FINAL LINE; the mark now shares it, so the row that shows the agent's last words is exactly the
  row that draws the closed ring. Pinned both ways.
- ⚠️ **Three marks is the CEILING for this column** (open ring, closed ring, dot). A shape here may only
  say what a hue cannot: whether the work is over, and who did it. Rounds 19–20 killed everything else.
- ❌ **Rejected: tinting the row's process-label slot** green/red instead. It adds no new shape, but it
  breaks the property that state reads down ONE column, and a coloured label fights the neutral-title
  rule the whole rail is built on.

## Cold reattach: the third churn pass is the progress bar that never entered a frame (2026-07-25)

- ✅ **Problem (field report):** a session where `git push` / `swift build` ran replays "cực nhiều
  dòng" on reconnect although the visible result is two or three lines. Measured on a synthetic
  `git push` (101 percentage ticks + the done line, 9,753 bytes): the whole existing pipeline —
  alt-screen strip, sync-frame collapse, distiller, query strip, EOL marks — returned 9,712 bytes,
  a 0.4% saving that is only the OSC marks. Progress reporters repaint ONE line with `CR` (or
  `CSI 2 K` + `CR`), never enter the alt screen (`AltScreenSegmentStripper` blind), never open a
  synchronized-output frame (`SyncUpdateFrameCollapser` blind), and live in the command OUTPUT span
  (`133;C`→`D`) that `ScrollbackDistiller` passes verbatim BY CONTRACT. Nothing owned this domain.
- ✅ **Fix — `LineOverprintCollapser`** (`SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT`, default-ON; runs
  after the sync collapse, before the distiller). A line is split at each cursor-to-column-0 motion
  (`CR`, `CSI G`/`CSI 1 G`) into REVISIONS. Droppability rests on ONE quantity: the columns a
  revision TOUCHES — paints a glyph into or blanks with an erase. A revision is redundant exactly
  when later revisions touch every column it did, because the last writer of each of those columns
  is then a later revision either way. Synthetic `git push`: 9,753 → 255 bytes. Real captured
  `swift build` PTY transcript: 56,233 → 34,142 with a byte-identical rendered screen.
- ⚠️ **Two model errors the tests caught, both worth keeping written down.** (1) "What a revision
  still SHOWS" is the WRONG quantity: a revision that only erases shows nothing yet still decides
  those columns, and dropping it resurrects what it wiped. Only "what it touches" is sound — the
  cost is that a repaint loop's FINAL `CSI 2 K` survives, one revision instead of thousands.
  (2) A line's opening revision does NOT start at column 0: a bare `LF` moves down keeping the
  column (the PTY's `ONLCR` is what normally makes it `CRLF`), so its span can reach past anything
  a successor covers. The column is carried across flushes and, when unknown — the ring opens
  mid-stream, or the previous line was unmodelled — that revision is never dropped. A line ending
  in `CRLF` re-anchors column 0, so the conservative state never cascades in practice.
- ✅ **Proof is differential, not assertional** (the herdr-parity habit): every case, plus seeded-fuzz
  streams over the full vocabulary (text, wide scalars, all three erases, carried SGR and
  `?25`/`?7`, and sequences that must force the verbatim fallback), is rendered through
  `TerminalScreenModel` before and after collapsing and the grids must match. The suite pins 2,000
  streams per run (~2 s); the 120,000-stream sweep that shook the design out was a one-time
  development run, not the enforced gate. The fuzz found both model errors above AND a real bug in
  `TerminalScreenModel` itself: `EL`/`ED`/`ECH` wrote `Cell()` directly, so erasing half a wide
  pair orphaned the other half — they now go through the same `clearWidePartner` path printing
  already used.
- ✅ **Review-hardening batch (same day, adversarial code review):** six holes closed. (1) The
  compaction backstop ran on UNSAFE lines — coverage is garbage there — and permanently forfeited
  the verbatim fallback; compaction is now safe-lines-only and an unsafe line stops splitting
  revisions instead (bounded memory either way, and unsafe-after-compaction emits the buffered
  survivors verbatim, which is screen-neutral because those drops happened while modelled). (2) A
  revision OPENING with a zero-width scalar attaches it to a predecessor's cell, so it marks the
  line unsafe. (3) `decodeScalar` accepted overlong UTF-8 and credited it width a terminal never
  paints — now rejected like surrogates. (4) The carry cap discarded one-shot `?25`/`?7` toggles
  wholesale; the carry is now STATE (last toggle per mode outside the cap, SGR sequences
  reset-aware and oldest-out) rather than a byte stream. (5) The unknown-start "never dropped"
  promise was encoded as `covers = Int.max`, which a full-coverage successor TIES (strict `>`
  dropped it); the keep rule — now ONE `keepMask` shared by flush and compaction — keeps
  `startKnown == false` explicitly. (6) `ICH`/`DCH` still orphaned wide-pair halves at their
  splice seams, the exact class the `EL`/`ED`/`ECH` fix above closed — both now blank split halves
  at their two seams (and `eraseCells` checks only its two edges, where a split can happen).
- ⚠️ **Accepted gaps (the first identical in kind to the sync collapser's):** a revision WIDER
  than the recording-time grid wrapped onto extra rows and its `CR` returned only to the last
  visual row, so dropping it loses the earlier rows. The pass has no grid width — the ring spans
  resizes and the client re-wraps at its own width, so that layout was never faithfully replayable
  — and width-aware progress reporters, which are what emit this churn, never exceed the grid.
  Second: a LINE whose first scalar is a combining mark attaches it across the line boundary into
  the already-emitted previous line; the target only moves if that line ended in an erase-only
  revision with drops before it, which no real reporter produces.
- ❌ **Not done: multi-line redraws** (`docker pull`, `cargo`: print N lines, `CSI N A`, repaint).
  Cursor-up marks the line unmodelled, so those replay verbatim as today. Modelling them needs a
  real grid, i.e. rendering the ring through `TerminalScreenModel` and replaying the DUMP — which
  loses colour and every scrolled-off row, and is a different design, not a bigger heuristic.

## Cold reattach becomes STATE-TRANSFER: render the screen model once, stop replaying history (2026-07-25)

- ✅ **Problem:** every reconnect with a fresh surface still replays SECONDS of byte history. The five
  churn passes (alt-screen, sync-frame, overprint, distiller, query/EOL strippers) minimize the BYTES,
  but the client still re-parses whatever survives, under real libghostty feed backpressure
  (`TerminalViewModel.ingestBatch` awaits `feedBackpressure()` per 256 KiB pass), and the documented
  accepted gaps (inline churn outside `?2026` frames, open command spans, multi-line cursor-up
  redraws) pass through raw. The cost is O(byte history); the client only needs the FINAL state.
- ✅ **Decision: cold PATH-A replay is composed by RENDERING, not by filtering.** The host feeds the
  ring + un-acked tail + detached-window out-FIFO backlog through `TerminalScreenModel` (extended
  with SGR cell attributes + scrollback capture) at the live PTY size, and sends the RENDERED
  equivalent stream: each scrollback line printed once (soft-wrapped lines re-joined so the client
  re-wraps at its own width), the screen grid painted once, cursor/scroll-region/charset/keypad/SGR
  state re-established, input modes re-asserted via the existing `TerminalInputModeStripper` net
  state. "Clean scrollback" becomes a construction guarantee instead of a heuristic outcome, and
  client re-parse cost drops to O(final state). The stream rides the SAME replay seqs
  (`ReplayBuffer.rechunk`, `mustCoverLastSeq` — ack-release semantics unchanged); the wire format is
  untouched on the output path. Gate: `SLOPDESK_SCROLLBACK_SNAPSHOT` (default-ON, `!= "0"`).
- ✅ **The detached out-FIFO backlog is consumed INTO the snapshot** (peek → compose → splice-out,
  the `compactDetachedBacklogForColdClient` discipline: sniffed control preserved on an empty
  replacement chunk, queue-gate accounting rebalanced). Without this the overnight-agent case —
  up to the 64 MiB detached budget of repaint churn, the bulk of the pain — would still replay
  after a clean snapshot. Post-snapshot PTY output drains normally with fresh seqs on top.
- ✅ **Warm reconnect stays byte-exact BELOW a threshold, snapshots ABOVE it.** A warm grid mid-TUI
  needs byte-exact continuation, so small tails replay raw exactly as before. When pending replay
  (tail + FIFO backlog) exceeds `SLOPDESK_SNAPSHOT_WARM_BYTES` (default 4 MiB — the "this will
  visibly take seconds" line), the snapshot preamble (`DECSTR`, `?1049l`, `ED 3`, `ED 2`, home)
  wipes and re-renders the client's world instead; on a fresh surface the same preamble is a no-op.
  A warm overflow with an EMPTY un-acked tail has no seqs to ride and falls back to raw (rare).
- ✅ **Fallbacks keep the old pipeline alive:** the distiller composition remains injected for the
  journal-restore path (PATH B/C — no authoritative grid size survives a daemon restart), for the
  seq-budget guard (rendered bytes must fit `replaySeqs × maxOutputFramePayloadBytes` — a
  pathological tiny-session expansion falls back to raw+distill), and for `SLOPDESK_SCROLLBACK_SNAPSHOT=0`.
- ✅ **Proof is differential + idempotent:** feeding `render(model)` into a FRESH model must
  reproduce the model's visible state (grids, styles, scrollback, cursor, modes), and rendering is
  a canonicalization — `render(feed(render(A))) == render(A)` byte-equal, fuzzed over the VT
  vocabulary corpus. The 400 ms redraw-jiggle stays only on the non-snapshot cold path: a snapshot
  paints every row the app believes is painted, so the differential-renderer blank-row hazard it
  worked around no longer exists.
- ✅ **`channelOpenAck` grows the designed-but-never-wired host-authoritative `resumeFromSeq`**
  (docs/20 §8.2), appended `Int64` BE, decode-tolerant when absent; the host acks BEFORE the replay
  on the same FIFO data link, so the client learns resume-vs-fresh authoritatively ahead of the
  first byte instead of inferring it from the first delivered seq (the inference stays as fallback).
- ⚠️ **Accepted gaps (documented, all strictly no worse than the stripper pipeline's):** OSC 8
  hyperlinks and app-set palette colors (OSC 4/10/11/12) are not modeled and drop out of the
  snapshot (the query stripper already dropped stale color state); `REP` immediately across the
  snapshot boundary repeats nothing (no real emitter splits a REP from its glyph); the saved-cursor
  slot restores position but not its saved SGR/charset; scrollback capture follows xterm (full-screen
  scroll region only, `ED 3` clears it, capped lines oldest-out).

## Snapshot replay follow-up: the compose walk gets fast, and the history gets CANONICAL (2026-07-25)

First real-hardware night exposed two defects in the state-transfer replay and one latent data-loss
hole; all three land together because the fix for the stall IS the canonicalization that fixes the
hole.

- ✅ **The model walk was ~1.2 MiB/s — a 64 MiB ring composed for ~55 s.** Every grid mutator
  copied the active grid out (`var grid = usingAlt ? alt : main`), which left TWO references on the
  row buffers, so the first cell write CoW-copied a whole row (plus the outer array) PER PRINTED
  CHARACTER. `takeActiveGrid()` now parks the stored slot on empty arrays so the local copy holds
  the ONLY reference and mutations run in place. With the scrollback cap eviction de-O(n²)'d (dead
  prefix index + amortized compaction instead of `removeFirst` per scrolled line), a contiguous
  feed walk, and an ASCII fast path (prebuilt single-scalar strings; width lookup short-circuits
  below U+0300), the walk measures ~21 MiB/s (`swift run -c release slopdesk-replay-bench`) —
  rendered output byte-identical before/after.
- ✅ **The retained history is ADOPTED after every successful compose** (`ReplayBuffer/
  adoptSnapshotReplay`): ring + un-acked tail are replaced by the rendered chunks exactly as sent,
  "as if the host had emitted the rendered stream all along". Two loads: (1) the consumed
  detached-window backlog got no seqs of its own — before this it existed ONLY in the delivered
  bytes, so the NEXT cold reattach replayed a history the backlog had vanished from (real data
  loss, e.g. an agent's overnight output missing from scrollback on the second reconnect); (2) the
  next compose walks the small canonical history instead of the raw ring. Warm re-reconnect
  mid-delivery resumes the rendered stream byte-exact because adopted == sent.
- ✅ **Detach folds the ring in the background** (`scheduleDetachedRingFold`, floor 128 KiB): the
  moment the client leaves is the one moment a multi-second render is free, so the acked ring is
  rendered once and spliced back (generation-guarded against concurrent ring mutations — a stale
  fold is dropped whole, never merged). The eventual reattach compose — the moment the user IS
  staring at an empty pane — walks O(canonical + delta). Memory falls out: an idle detached
  session's ring collapses from up-to-64 MiB of churn to the rendered size.
- ✅ **DECSCUSR joins the modeled state.** The zsh integration sets a bar cursor per prompt
  (`precmd` → `ESC[5 q`); the model consumed all intermediate-family CSIs unmodeled, so the
  snapshot silently reset every reattached pane to a block cursor. The model now tracks the
  last-wins shape (RIS resets it), the renderer re-emits it after keypad state, and the preamble
  wipes with `ESC[0 q` so a warm-overflow re-render can't inherit a stale shape.

## PATH B joins the state transfer: journal restore renders a TRANSCRIPT (2026-07-26)

The last replay path still on the distiller was the fresh-spawn journal restore (hostd restart /
TTL eviction / shell death → `spawnFreshShell`): the blocker was that after the daemon dies there
is no authoritative grid size to parse the journal at. Decision: the parse-correct size is the one
the bytes were EMITTED for — persist it beside the journal and render the restore like PATH A.

- ✅ **Size sidecar** (`<uuid>.scrollback.size`, "rows cols"): every APPLIED winsize is recorded —
  `startRelay()` seeds the spawn-time size (a headless CLI pane may never send `.resize`), each
  flushed client resize overwrites it (last-wins, deduped, atomic, on the journal queue). The
  journal file itself stays raw/headerless; a missing or garbled sidecar decode-fails to the
  distiller path (no-backcompat: no migration, old journals just take the old path once). Delete/
  sweep reap the sidecar with its journal, plus fully-orphaned sidecars.
- ✅ **`TerminalReplaySnapshot.composeTranscript` + `renderTranscript`** — the fresh-spawn variant
  of the snapshot render. The restored bytes front a NEW shell, so the transcript is CONTENT-ONLY:
  scrollback and main grid form one uniform run of rows (a soft-wrapped logical line straddling
  the scrollback↔grid boundary re-joins — splitting there also broke the fixed point, because the
  re-feed's scroll phase moves the boundary), blank edge rows are trimmed (interior blank lines
  kept), SGR styled per cell and reset before every line feed, ending on a fresh line for the new
  prompt. No preamble (the restore gate guarantees a cold surface), no alt screen (the dead TUI
  cannot resume; the main screen beneath it is what the raw path's `?1049l` revealed too), no
  private modes, no cursor/DECSCUSR state, no input-mode reassert, no sanitize suffix (mode-free
  by construction). A dead stream's trailing incomplete escape/UTF-8 fragment is DROPPED, not
  held back — nothing will ever continue it.
- ✅ **Proof:** transcript-of-transcript is a byte-exact FIXED POINT — pinned on curated churn and
  on the existing 300-seed fuzz vocabulary (this is what keeps repeated daemon restarts at zero
  render growth). Store-level tests pin the sidecar lifecycle (record/last-wins/degenerate-reject,
  delete/sweep, corrupt-sidecar fallback, composer-vs-distiller selection, the
  `SLOPDESK_SCROLLBACK_SNAPSHOT=0` kill switch — one env gate governs BOTH replay paths); a real
  PTY test pins both sidecar writers; the hostd-restart E2E now asserts the "(snapshot replay)"
  restore log line on the shipped binaries and the absence of the sanitize suffix.
- ✅ **Observability:** `spawnFreshShell` logs "restored N journaled bytes (snapshot|distilled
  replay)" — the PATH-B sibling of the reattach "replay in N ms" line.
- Accepted: the compose still runs synchronously on the channel-open path (a full 64 MiB journal
  ≈ 3 s at the measured ~21 MiB/s — once per pane per daemon restart, replacing a much longer
  client-side parse; the distilled path was synchronous there too). Restores at a size the client
  immediately changes re-wrap client-side like any transcript line.

## The title comes back: type 21 joins the reattach re-assert (2026-07-26)

> Phase 1 of [45 — Multi-client state sync](45-multi-client-state-sync.md). Fixes the reported bug
> (`nvim` titles a pane; quit the client, reopen, the row reads `vi .` forever) with **no wire
> change and no golden churn**. The remaining phases move ownership; this one closes the leak.

- ✅ **The class of bug, named.** A host-derived fact extracted by a stateful host parser was exposed to clients **only as an edge-triggered event**. The host's memory of "what is true right now" was wired to an unrelated consumer (`list-panes`), so any client that started listening after the edge fired had permanently missed it and **had no way to ask**. At one client this is a stale sidebar; at N clients it is silent, permanent, undetectable divergence. Every other activity truth (23/26/27/32/33/34/36) was already re-asserted on reattach — type 21 was the sole omission, and it was the one the user could see.
- ✅ **`reestablishActivityOnReattach()` re-asserts `.title(_currentTitle)`, skipping empty.** Empty is not "no title": `publishAgentEmission` sets `_currentTitle = ""` as the ownership-RETIREMENT signal (pinned by `MuxChannelSessionTitleRetirementTests`), so re-asserting an empty would resurrect a dead agent's `✳ <topic>` on every reconnect. Skip-when-empty is the correct reading of both producers.
- ✅ **The `.title`-after-`.commandStatus` ordering is load-bearing, and temporary.** Until the host ships its own `pane/titleFresh` verdict (45 §4.4), the CLIENT decides whether to trust a title by comparing arrival stamps, so the type-21 must land after the type-23 in the same batch. Pinned by `testTitleIsEnqueuedAfterCommandStatus`; **deleted in Phase 4** along with the comparison itself.
- ✅ **A title with NO command-start stamp is TRUSTED (`programTitle(for:)`).** Requiring BOTH stamps meant a shell without OSC-133 integration (Starship, a bare `sh`) — which never stamps `paneCommandStartedAt` — could never show a program title at all. That is the hookless half of the same bug, and `.title` re-assert alone does not fix it: `commandStatusForReattach()` returns `nil` at a prompt, so the second stamp never arrives. Safe because the host only ever asserts a title it CURRENTLY holds. A title predating a KNOWN command start is still rejected — the relaxation is scoped to a MISSING stamp, not a stale one.
- ✅ **`list-panes` enumerates detached sessions.** `listPanesForControl()` read only `muxSessions + controlSessions`, so a pane that survived a client quit — precisely the reported scenario — was invisible to the one "describe all panes" API in the product. New `DetachedSessionStore.allSessions()` (ordered by `detachedAt`; every other production API existed except enumeration). The three sources are disjoint by construction: `handleLinkDown` removes from `muxSessions` before `detachMuxSession` inserts, and `claim` removes before the reattach re-registers.
- ✅ **The frozen golden keys were not actually pinned by anything.** `scripts/golden-check.sh` diffs the 35 EMITTED keys and prints the other 13 as "XCTest-pinned, not emitted" — but **no test loaded the corpus at all**. The suites those keys name pin BEHAVIOUR with hand-written cases, never the committed BYTES. Two of the 13 (`hostOutputSniffer`, `terminalModeTracker`) sit directly on the PATH-1 title path, so a change there produced no golden signal AND no XCTest signal. New `HostOutputSnifferGoldenGuardTests` replays the frozen vectors through the live sniffer (driving the injectable `clock` from each step's `nowMs`, which is why the duration bytes are reproducible at all).
- ✅ **First catch: `invalidUtf8Title` had already rotted.** The corpus expected an EMPTY type-21 for `ESC ] 0 ; \xff\xfe BEL`; the live sniffer emits nothing, because the deliberate empty-title drop (zsh/p10k emit a blank OSC 0/2 during prompt redraw, and wiring it would clear the client's shown title) post-dates the vector. **The code is right and the corpus was stale** — and it matters more now than when it drifted, since an empty type-21 is the retirement signal. Hand-merged the vector to `messagesHex: []`; corpus stays at 48 keys.
- ✅ **Scope limit, stated.** The client's `.title` sink is gated on `SettingsKey.titleShellControlledEnabled` (default ON), so the fix holds for every default install and is a deliberate no-op where the user turned shell-controlled titles off. `_currentTitle` lives in memory on `MuxChannelSession`, so a **daemon** restart still degrades the title until Phase 5's persistence. And if a program genuinely never emits an OSC 0/2 title, `vi .` **is** the last true title — Phase 4's `pane/runningCommand` + `pane/foregroundProcess` covers that variant.

## Multi-client: hostd owns the workspace document (2026-07-26)

> The architecture record for [45 — Multi-client state sync](45-multi-client-state-sync.md).
> Supersedes [22](22-workspace-architecture.md) §1.1 for **ownership**; the tree-of-intent ⟂
> table-of-liveness split, the pure `WorkspaceTreeOps`, and the `makeSession` test seam survive
> verbatim. These rulings land BEFORE the code that implements them (Phases 2–6).

### 1. The three-bucket ownership split

- ✅ **The classification test, stated once:** *would two people looking at the same session disagree about a **fact**, or about a **view**?* Facts are HOST-TRUTH. Views are DEVICE-LOCAL. "Who is here and what are they looking at" is PER-CLIENT-PRESENCE — fanned out, TTL-expired, never persisted, never versioned.
- ✅ **HOST-TRUTH:** topology (sessions/tabs/splits), `activeTabID` by IDENTITY not index, `focusMRU`, the closed-tab ring, presets and templates (they name HOST cwds and spawn HOST commands), per-pane title/`liveTitle`/`titleFresh`/cwd/projectKey/foregroundProcess/`runningCommand`/agent state/progress/`liveness`/`completionEpoch`/grid, the video pane's TARGET identity, and the per-project git summary.
- ✅ **DEVICE-LOCAL:** everything in `PreferencesStore` (a 27″ Studio and an iPhone must not share a font size), window chrome, scroll/copy-mode/selection *inside* a pane (tmux: "the visible position is a property of the client not of the window"), `videoModesByTarget`, `seenCompletionEpoch`, and the notification DELIVERY gate.
- ✅ **Pane identity becomes HOST-MINTED.** The host's mux `sessionID` **is** the pane objectID. A client spawning a pane sends an intent and learns the id back. Today's client-minted UUID gives two devices no shared vocabulary for "the nvim pane". `PaneSpec.resumeSessionID` is deleted — the host-minted id is the rendezvous identity.
- ✅ **ctl-spawned panes ARE in the document**, parented to `root/unattachedSessionID`. Otherwise the host holds two disagreeing pane inventories and the premise of the design is false.
- ✅ **A delete removes an OBJECT, never a single field.** A field is retired by setting it to a ZERO-LENGTH value, and zero-length is a first-class value the projection honours — because `""` is already meaningful on this wire (the type-21 title retirement).
- ❌ **REJECTED: CRDT / OT.** Zed is the decisive precedent: a real CRDT for **text buffers**, plain host-authoritative RPC broadcast for the **Project/Worktree tree** — the structurally identical case to ours. With one serialization point there is nothing to merge.
- ❌ **REJECTED: an operation log with delta compaction.** Snapshot-at-current-`stateNum` instead. Cost is then O(tree), never O(elapsed): no retention window, no compaction, no `OffsetOutOfRange` equivalent, and reconnect-after-four-hours is the same code path as steady state.
- ✅ **`epoch: UUID` is the no-migration directive expressed on the wire.** Minted at every hostd start. Without it a restarted daemon counts `stateNum` back up and a returning client accepts a delta computed against a *different document* — divergence that is permanent, silent, and has no detector. A foreign epoch means reset-then-snapshot: the same path as a missed frame.
- ✅ **The Inspector (PATH 3) stays a derived, lossy read model.** The document is authoritative; the inspector is not reconciled into it.
- ✅ **Blast radius, stated out loud.** A compromised mesh peer goes from "can attach one pane" to "can restructure the workspace and close tabs". Security remains the WireGuard mesh; **no app-layer auth is introduced** — the client label on the wire is a LABEL, not a credential, checked nowhere and granting nothing.

### 2. Focus is host-truth; `videoModesByTarget` is not

- ✅ **`Session.activeTabID` / `Tab.activePaneID` are HOST-TRUTH.** They are not a render preference: they determine `successorAfterClose`, notification targeting, and what a fresh client opens into. tmux puts `session->curw` server-side.
- ✅ **The escape hatch ships in the SAME phase**, not later: a device-local `followSessionFocus` (default **ON macOS / OFF iOS**). Unfollowed clients carry their view in presence, so picking up a phone can never yank a Mac's screen.
- ✅ **The 2026-07-22 `videoModesByTarget` ruling stands, on two of its three legs.** Quoting it: (a) *"Immersive is a client-LOCAL CGEventTap — the host cannot own another machine's keyboard routing"* — **stands**. (b) *"host-side durability would need a persistent per-pane identity the host doesn't have (PaneID/workspace is a client concept)"* — **OBSOLETE**, pane identity is now host-minted. (c) *"a second client (iPad/macbook) viewing the same host must NOT inherit the first client's per-pane view prefs"* — **stands**. (a) + (c) alone carry the ruling, which is a stronger argument than the original.
- ✅ The video **target identity** becomes topology (both clients must agree "tab 3 slot 2 is a video pane on Display 1"); the **modes** stay device-local.

### 3. PTY size under N clients: monotone min-fold over ATTACHMENT

- ✅ **A subscriber contributes iff it holds an open `channelClass == 0` channel for that pane.** That set IS the refcount. Grid is `min(cols)`/`min(rows)` over contributors behind a **750 ms settle timer**; a pane with **zero** contributors keeps its last size rather than snapping to 80×24. **iOS is size-passive by default** (tmux `ignore-size`). Wire type 11 `resize` stops being a command and becomes a **contribution** — no wire change.
- ✅ **BOTH `pty.setWindowSize` sites route through one `applyResolvedGrid()`** — the client path AND the ctl-socket `resizeForControl` path. Leaving the second outside the fold silently breaks the monotone-min invariant.
- ❌ **REJECTED: WezTerm's / `screen -x`'s unconditional last-writer-wins.** Two clients at different sizes fight and the loser is simply told the new dimensions.
- ❌ **REJECTED: an input-keyed driver latch.** It has NO hysteresis: two clients typing alternately flap `TIOCSWINSZ` + `SIGWINCH` + a full TUI repaint on every exchange, and one stray byte from a pocket reflows a 200-column Mac. A min-fold is monotone and settles; a latch always flaps.
- ❌ **REJECTED: a presence-keyed predicate.** A 30 s heartbeat TTL is not a resize request — network jitter on a cellular iPhone would SIGWINCH a Studio's nvim.
- ⚠️ **Acknowledged cost:** zellij Discussion #5066 (smallest-client-wins is a documented pain point). The iOS-passive default removes the worst case; the resolved grid + contributor list are published so a non-contributing client renders a LABELLED letterbox rather than guessing.

### 4. The badge fact is shared; the acknowledgement is not

- ✅ **Objective host `pane/completionEpoch` (monotone counter) + device-local `seenCompletionEpoch`.** Clients agree on the FACT and disagree on the ACKNOWLEDGEMENT. The host holds **zero** per-client acknowledgement state.
- ❌ **REJECTED: tmux's server-side shared activity flags** (one client reading clears everyone's badge) **and a host-held `unseenBy: Set<ClientInstanceID>`** — unbounded, no GC, undefined for a client that was offline when the event fired, undefined across a restart.
- ✅ **Types 22/25 fan to every client and each client gates locally** (`NotificationPolicy.shouldDeliver`). Duplicate banners across a user's own devices are **the point** — you want the banner on the machine you are at. Host-global `hookAuthority` suppression is unchanged.

### 5. Workspace channel transport rules

- ✅ **`channelClass`: 0 PTY · 1 workspace · 2 read-only observer.** The field is already encoded, decoded and golden-pinned, and read nowhere in the host — the seam is free. Workspace routing goes in `spawnMuxChannel` **before** the pane-routing critical section, so the one-shell-per-sessionID invariant is untouched.
- ✅ **The workspace channel must NEVER use `enqueueControl`.** It sheds NEW messages past `maxControlOutQueued = 1024`, so a shed snapshot leaves a client pinned at `stateNum 0` **with no retry trigger** — a silent, permanently blank workspace. The channel owns its own send task with **depth-1 coalescing**: a pending diff is discarded and recomputed, never queued. Host memory is O(clients × state) regardless of how slow a client is; a sleeping iPhone is free.
- ✅ **Diff from the ACKED base, not the last-sent base** (mosh SSP). A diff is then a set of independent property assignments, so duplicates and reorders are no-ops *by construction* and a lost frame self-heals on the next tick. **There is no retransmit path on either side.**
- ✅ **Only kinds 0 (snapshot) and 1 (diff) advance `stateNum` or trigger an ack.** A presence or intent-result frame that advanced it would make the host retire, via `assumedAcked`, a diff it never sent — permanent silent divergence on the very first `renameTab`.
- ✅ **The client fast-path overlay may NEVER write `entries`.** The retained type-21/26/27/32/33/34/36 pushes keep painting sub-frame, but into a separate `fastPath` layer that any diff erases. `entries` stays provably `apply(diffs, base)` — writing pushes into it would freeze a producer disagreement forever, which is the exact bug class this work exists to eliminate, reintroduced as an optimisation.
- ✅ **Conflict rule, one sentence:** *the last write to a given `(kindTag, objectID, field)` key wins, ordered by arrival at the single `HostWorkspaceDocument` actor* — no merge, no timestamps, no vector clocks. Figma's model. Anti-flicker: while a local change is unacknowledged, conflicting server values are held back rather than applied-then-corrected.
- ✅ **State plane vs byte plane:** data arriving on a pane channel the state plane has already retired is **DROPPED** — not applied, not an error. A pane surface is torn down only after its own `channelClose`, never on a state-plane edge alone. The untrusted-input idiom applied to our own host.
- ✅ **Hard sequencing gate before fan-out:** `closePane`/`closeTab` reap **unconditionally** and `channelClose` **every** subscriber; only `detach` is refcounted. A refcount-aware close would leave a shell running with no UI anywhere and no document entry.
- ✅ **`SLOPDESK_SUB_LAG_BYTES` (default 32 MiB) evicts a laggard rather than letting it stall the pane**, deliberately below the real 64 MiB offline gate; `ReplayBuffer` retention releases at `min(lastAckedSeq)`; **the PTY drain pauses only when the LAST subscriber is gone**, preserving today's detached-budget behaviour exactly. Eviction is affordable precisely because the 2026-07-25 snapshot-replay work made a cold reattach cost one screen, not a history. **Amended 2026-07-28** ("The fan-out laggard soak", below): the drain also pauses when the FASTEST member stops consuming — "the last subscriber is gone" is not the same statement as "nobody is consuming", and a pane that shrank back to one member had no producer bound at all.

### 6. Doc corrections made in this pass

- ✅ [20](20-wire-protocol.md) next-free type bytes read 17 / **36** while 36 was `agentSessionIntent`; corrected to 17 / **37**, with a note that these numbers are prose and `WireMessage.swift` is the source of truth.
- ✅ [20](20-wire-protocol.md) "Replay-buffer caps" read 64 MiB ceiling / 4 MiB offline gate; the code is **256 MiB / 64 MiB**.
- ✅ [22](22-workspace-architecture.md) claimed sessionIDs are NOT persisted; `PaneSpec.resumeSessionID` persists them and Stage-2 resume is default-ON. Its `SlopDeskClientUI/…` paths are also stale (the code lives under `Sources/SlopDeskWorkspaceCore/Workspace/`).
- ✅ `WorkspaceStore.blockBookmarks`'s doc claimed stable-`PaneID` keying while the code uses the per-materialization `bookmarkScopeKey`. **Comment fixed, code kept** — the scope key is deliberate (a relaunch must not re-apply a prior run's raw block indices onto unrelated commands).

---

## Multi-client Phase 4: what the code decided that the design did not (2026-07-27)

> Amends [45 — Multi-client state sync](45-multi-client-state-sync.md) §5–6 with the rulings that
> only surfaced once the channel existed. Each of these was found by a test, not by review.

### 1. `stateNum` starts at 1, never 0

Zero is the "I know nothing" sentinel a client sends in `subscribe`, and the base every snapshot
declares. If the host could also legitimately BE at zero, a client that had genuinely received and
acked the opening document would be indistinguishable from one that had never connected — and would
be re-snapshotted forever. Found by `testAChangeAfterTheAckArrivesAsADiffFromTheAckedBase`, which got
a second snapshot where a diff belonged.

### 2. One send outstanding at a time — which is what depth-1 coalescing MEANS

§5.5 gives the client the rule "`baseStateNum != stateNum` → DROP and resubscribe". The host must
therefore never declare a base the client does not hold. Recomputing from the acked base is necessary
but not sufficient: while a frame is unacked, the acked base is STALE, so a second frame sent
against it names a state the client has already moved past, and the client's own drop rule turns a
burst into a resubscribe loop.

**The host holds further updates until the previous frame is acked.** They coalesce into the pending
slot and ship as one diff. 500 versions with no ack in between produce exactly ONE diff, and the
500th value lands when the ack arrives. This costs one RTT of update latency and buys a natural rate
limit; for titles and cwd that is a feature. It is safe without a retransmit path because this rides
the mux CONTROL sub-channel, which is TCP: a frame is only ever "lost" with the link, and the link
taking the channel down is itself the resubscribe trigger.

### 3. `PaneLiveness` lives in the MODEL target, not the host

§6.2 filed it under `Sources/SlopDeskHost/`. Both ends need it — the host writes `entries()`, the
client reads `init(paneID:entries:)` — and one round-trippable value beats an encoder and a decoder
maintained apart. It also buys a headless round-trip test with no PTY in sight, which is where the
four `titleFresh` rules are pinned. The host keeps only `PaneLiveness.capture(from:)`.

The spec's `assertions() -> [WireMessage]` is NOT implemented: the reattach re-assert's messages come
partly from `agentDetector.reestablishOnReattach()`, which MUTATES the detector (it re-anchors so an
unchanged state still re-emits). A pure snapshot cannot produce them. The two consumers stay separate
until Phase 4c retires the message half.

### 4. A liveness merge CLEARS before it writes

Writing only the fields a record carries would latch `runningCommand` after the command finished and
`agentLabel` after the agent exited — the same "edge published, current value retained nowhere"
failure this document exists to end, moved one layer up. `merge(paneLiveness:)` replaces exactly the
liveness field set and leaves topology alone.

### 5. Facts are SWEPT, not pushed

The per-pane truths come from at least five independent producers — the sniffer's read-loop thread,
the foreground poll task, the hook socket, the blocks segmenter, the project-key resolver. Wiring
each one to the document separately is precisely how a fact goes missing. `reconcileWorkspaceDocument`
re-captures every pane and merges the lot: correct by construction, and free when nothing changed
because `stateNum` only moves when the value did. Event sites KICK a pass rather than carry one, so
steady-state latency is a hop; the periodic tick is only a backstop for facts with no edge to hang a
kick on.

### 6. Project object ids are MINTED, not `UUIDv5(projectKey)`

§5.3 proposed a v5 UUID, which needs a SHA-1 the host target does not otherwise link. A minted id is
exact where a hash is merely unlikely to collide, and its only cost — a different id after a restart
— is invisible: a restart mints a new `epoch`, every client resets and re-snapshots, and
`project/key` carries the path the client actually joins on.

### 7. The client awaits `channelOpenAck` before its first request

`channelOpen` is announced on the DATA link while `subscribe` rides CONTROL, so a subscribe sent
immediately can beat the host's registration of the control sub-channel. The frame is dropped and the
client waits forever for a snapshot that never comes. Same discipline as PATH A's reattach. This
presented as a FLAKE under the full suite and passed in isolation — which is how open-order races
always present, and why [CLAUDE.md](../CLAUDE.md) says in-memory loopback misses them.

### 8. Loopback tests POLL a collector; they never await `inbound.next()`

Awaiting the iterator strands xctest the moment an expected frame does not arrive, and a hung suite
tells you nothing while blocking the gate. With the `channelClass` route reverted, the tests now fail
in six seconds with "timed out waiting for 1× snapshot".

## Multi-client Phase 4d: two silent defects, and where the rest of it actually lives (2026-07-27)

Phase 4c shipped the client half. Two of its rules were wrong in ways nothing could report.

### 1. The document is keyed by the HOST's pane id

4c wrote and read the mirror under `PaneID.raw`. That id is minted on the CLIENT when a pane is
created; the document keys panes by the id the host mints on channel open. Two different UUIDs, and
no decoder can tell them apart.

So host truth landed under keys the UI never queried — the document was inert on a live client — and
worse, the two mirror layers were keyed APART, which makes the erasure rule that keeps them disjoint
unreachable. A client guess the host contradicts would have won forever: the exact bug the document
exists to end, reintroduced one layer down. The 4c suite missed it by building its fixtures from
`paneID.raw`, asserting the mapping it also assumed.

`PaneSpec.resumeSessionID` already held the host's id — `onResumeIdentitySnapshot` fires on every
connect, not only under the detach flag, and the store persists it — so the mapping was on disk the
whole time and survives a relaunch exactly as the document does. `documentPaneID(_:)` reads it.

The local-id FALLBACK is right for the mirror, whose overlay is this client's own namespace, and
wrong for anything shared. `documentPaneIDIfKnown(_:)` is the shared-surface form: a tree-local id in
the presence roster names nothing on any other client.

### 2. A mirror change repainted nothing

The mirror is a plain value in a plain box, so that its convergence is provable with no SwiftUI near
it — which also means folding a frame in is not `@Observable`. A read funnel consulting only the
mirror registered no dependency, so the row held its old value until an unrelated mutation happened
to repaint it. That is precisely the multi-client case: a client whose only source of news is the
document changes nothing of its own, so the unrelated mutation never comes.

`workspaceMirrorRevision` is the box's observable shadow, bumped from `onChange`. It carries no data
— the `completionFlashTick` idiom.

### 3. Only `runningCommand` was worth routing through the document in Phase 4

The obvious reading of §7.2 is "move every per-pane fact to the mirror". Most of them do not need it:
`ClaudePaneDetector.reestablishOnReattach` already re-asserts types 26/27/36, so foreground process,
agent status, label and intent all recover on a returning client by themselves. Routing them would
have been churn with no observable effect until Phase 5 brings the ROWS a second client would render
them in.

The open command's TEXT is the exception, and it is not re-asserted by anything: it lives in the
client's `CommandBlock` model, which is per-materialization. A pane whose bytes were never rendered
here has no blocks at all, so a busy row could say no more than "zsh".

`cwd` and `projectKey` stay on `PaneSpec` for the same reason — persisted, restored cold, and about
to be re-homed wholesale when Phase 5 makes topology host-owned.

### 4. The unread finish is a comparison; "seen" is scoped to the document epoch

`paneUnseenDone` was the fact itself, so it disagreed between clients, died on relaunch, and could
not be learned by a client disconnected across the finish — the host's done→idle decay had already
taken the edge. The counter is askable; the Set survives only as its projection.

Two rules the mechanism needs:

- The comparison is INEQUALITY, not `>`. A restarted daemon counts from zero again, and a `seen`
  stranded above the live counter silences that pane forever. For the same reason the persisted map
  carries the document epoch it was recorded under and is dropped when that changes: one re-announced
  finish beats permanent silence.
- A zero counter must never be RECORDED as seen. Every pane reads zero until the document arrives,
  so writing it erases a restored map before the channel has said which document this is.

"A finish you are LOOKING at is a finish you have seen" moves from the EDGE to the COMPARISON. Stated
at the edge it loses to ordering the moment the document is live, because the host's counter and this
client's own `.done` arrive on different paths in no guaranteed order.

### 5. "Held by `<label>`" is blocked on Phase 6, not deferred

§7.2 filed it under Phase 4. It cannot be: attachment needs the pane channel to declare whose it is,
and only the workspace channel's `subscribe` carries a `clientInstanceID` — which is why the host
fills the roster's `panes` list with nothing. The declaration arrives with the pane-observer class.

The roster does know who is VIEWING each pane, which is honest on its own and now reads in the row
tooltip. Rendering ownership on a viewing record would have been a guess dressed as a fact, and
suppressing `channelOpen` on the strength of it would make panes unopenable for a reason the user
could not undo.

### 6. `pane/lastActivityMS` stays unstamped

The session keeps no last-activity latch and the only place to make one is the PTY read path — a
wall-clock read per chunk, on the hot path, for a field nothing reads. `0` is already the record's
own "never observed", so the absence is expressible rather than a lie.

## Multi-client Phase 5: the layout becomes host truth (2026-07-27)

[docs/45](45-multi-client-state-sync.md) Phase 5. Phase 4 shipped the per-pane FACTS, which repair a
degraded row; two clients still held two separate trees, so a tab opened on the Mac simply did not
exist on the phone. Six decisions the plan did not settle, or settled differently.

### 1. New object ids are proposed by the CLIENT, not minted by the host

§4.1 has the host mint pane ids and the client "learn the id back". It does not, for one reason:
latency. An optimistic overlay cannot insert a leaf it has no id for, so a host-minted id makes every
split wait a round trip before anything appears on screen — worst exactly where the round trip is
longest. `splitPane`, `spawnPane`, `spawnTab` and `newSession` therefore carry the id, and the host
validates rather than mints: a proposed id already in use — **including one parked in the closed-tab
ring**, which is still a real pane a reopen will bring back — is `rejectedInvalid`. Aliasing two
panes onto one PTY is the same hazard the mux's own exclusivity check exists for.

The side benefit is that a retried intent is idempotent, which the plan's version could not be.

### 2. Zoom and sync-input are ASSIGNED, never toggled

Both were toggles client-side, where a toggle is unambiguous. Over shared state it is not: the result
depends on how many clients sent it, and two clients zooming the same pane cancel out. An idempotent
assignment cannot have that bug, and it is what makes a duplicated intent free.

### 3. The closed-tab ring holds whole TABS, not ids

§5.3 gives `root/closedTabRing` as a `TabID` list. A `TabID` alone cannot rebuild a tab, and ⇧⌘T has
to put back the split tree and every pane's spec — so the ring names tabs whose `tab/*`,
`splitNode/*` and `pane/*` entries are still in the document. **A closed tab is exactly a tab whose
`tab/sessionID` back-pointer names a session that does not list it in `tabOrder`.** No new grammar;
one new rule, which is that the reaper leaves them alone.

### 4. The reaper had to narrow, and "not captured" is now three cases

Phase 4's rule — reap what the capture pass did not report — was correct while the document held
liveness only, because "not captured" and "not a pane" then coincided. With topology here they do
not: a pane the host restored from disk has no process (that is what a restart IS) but is a real pane
in a real tab, and the old rule would have erased the user's layout on every daemon restart. One pass
now decides all three: captured → its liveness; in the topology but not captured → `liveness = 2`,
keeping `cwd` and `projectKey`, which describe a PLACE rather than a process; neither → reaped.

### 5. `pristine` is answered by the FILE, and any accepted intent ends it

`adoptWorkspace` asks "has this host ever had a workspace of its own?". The answer is whether a file
exists — and it has to be asked BEFORE `load()`, which mints a default when there is nothing to
restore and so can no longer tell the two apart. Any accepted intent then ends pristine, including
one that changed nothing: a client that renamed a tab to its own name has still taken ownership.

### 6. The optimistic patch retires on a FRAME COUNT, not a `stateNum`

`intentResult` carries no state number, and does not need one. The host bumps `stateNum` and queues
the new document BEFORE it queues the result, and the result is not gated on the outstanding frame —
so the first document frame to arrive after an `applied` result provably already contains that
intent's effect. Retiring on the answer itself would blink the old layout back for one frame;
retiring on a frame that arrived BEFORE the answer would show the old layout until the next unrelated
change. A refusal is the exception and snaps back at once, because waiting keeps showing the user
something the host has already said is not true.

Two findings from wiring it up that are not decisions but bite the same way:

**Exactly ONE document frame is outstanding at a time.** A test client that acks once sees one more
frame and then silence, which reads as the host having stopped publishing. It is the flow control
working: while an ack is pending, updates coalesce into the pending slot, which is what keeps every
diff's `baseStateNum` equal to what the client actually holds.

**A test that constructs a `HostServer` with the document enabled must inject a store.** `load()`
mints and the persist sink writes, both against `<Application Support>/SlopDesk/workspace-state.json`
— so one test against the default path silently replaces a workspace somebody is using.

## Multi-client Phase 5b: the pane's facts get somewhere to live (2026-07-27)

[docs/45](45-multi-client-state-sync.md) §7.3. Phase 5b moved every per-pane fact off `PaneSpec` and
into the document, read through `HostWorkspaceMirror`. Three rulings the move forced.

### 1. `SLOPDESK_WORKSPACE_DOC` stays default-OFF, and the client is not allowed to need it

The open question in docs/45 §10 was whether the flag flips ON with this phase. It does not. The
reason is a rule, not a schedule: **the flag gates a TRANSPORT, so nothing on the render path may
depend on it.** A client with the flag off must draw the same sidebar as one with it on, one RTT
staler — otherwise "off" is not a bake-in switch, it is a second product with its own bug list, and
the no-backcompat directive forbids exactly that dual path.

That is why the store still owns `tree`, and why the facts that left `PaneSpec` land in the MIRROR
rather than in the channel: the mirror has two producers, and the per-pane control pushes are the one
that works with the flag off. The flag flips when the store's mutations become intents (the remaining
Phase 5b step) — at which point a flag-off client would have no layout at all, and the answer is to
flip it, not to keep a tree-owning path beside the projection.

### 2. The client's cache is a PICTURE, and the two layers say which

`workspace-cache.json` holds what this device last knew about ONE host's panes, gated on
`host:port` — the only host identity available before connecting. What it seeds is split by what the
fact IS, and the split is the whole reason it can never go stale:

- `pane/spawnCwd` is TOPOLOGY — where this pane's shell is asked to start. It joins the seeded
  topology, because a respawn after a host restart has no live shell to ask and no other source.
- `pane/cwd` and `pane/projectKey` are LIVENESS — where a shell IS. They go to the mirror's FAST
  PATH, which the erasure rule deletes for any key a host frame supplies.

No promotion step, no fallback title, no freshness heuristic: those three are how a cache outlives
the fact it cached, which is the `vi .` bug in its original form. The epoch is deliberately not a
gate — a hostd restart mints a new one while restoring the document byte-identically, and gating the
paint on it would blank the window on exactly the reboot case the cache exists for.

**The reopen ring counts as live.** A closed pane's facts are not reaped on the close edge, because
⇧⌘T restores the original `PaneID`s and would otherwise bring the pane back with no directory. The
host's applier already unions `closedTabs` into its live set; one document with two answers is the
failure mode.

### 3. Shape can no longer tell a real session from the throwaway default

`On Launch = New Window` skips its `.previous` snapshot when `workspace.json` is "the default the
store autosaved last time". With the pane's facts gone from the tree, a real single un-renamed
terminal is structurally IDENTICAL to that default — and skipping on shape destroys it, taking with
it the `PaneID` the host has a PTY filed under, which can then never be reattached.

So the skip takes two facts: default-shaped AND a sidecar already exists. With no sidecar there is
nothing to lose by writing one. `isDefaultTreeShape` is a shape test and says so; the ambiguity is
resolved where the consequence is.

Two things that follow, and are not decisions:

**`TreeWorkspace.currentSchemaVersion` goes to 12.** The retired keys are outside `CodingKeys`, so a
file from the previous shape decodes "successfully" and the next autosave rewrites it without the
user's presets and templates — silently, with no `.corrupt` copy. Stale data has to decode-FAIL.

**An optimistic patch needs a driver.** `expirePending` had none: a send that threw left a patch
standing over host truth forever. The failed send now drops its own patch at once (the host was never
asked — there is no answer to wait for), every inbound frame sweeps before it is folded in, and a
one-shot backstop covers a host that accepted and died on a channel too quiet to sweep itself.

## Multi-client Phase 5b: the store's mutations become intents (2026-07-27)

[docs/45](45-multi-client-state-sync.md) §7.2. The step the entry above defers: `WorkspaceStore.tree`
stops being a stored `TreeWorkspace` and becomes a projection of `workspaceMirror.topology`, and every
mutator becomes an intent. Two rulings, and the seam that makes the cutover reviewable.

### 1. `SLOPDESK_WORKSPACE_DOC` flips default-ON on BOTH ends in the SAME commit

Not a schedule — a coupling. A host with the flag off answers `sendOpenAck(accepted: false)`, which
the client publishes as `.refused` and never retries, because a refusal is a definite answer rather
than a transient failure. So a default-ON client against a default-OFF host holds `topology == nil`:
zero sessions, a blank window, and no error anywhere, since a nil topology makes `stageIntent` return
`nil` and every mutation a silent no-op. The two defaults move together or not at all.

The flag keeps its `!= "0"` shape on both ends, which is this repo's default-ON idiom.

Two things this ruling costs, named rather than discovered:

**`syncInputTabs` becomes persisted host truth.** It rides `tab/syncInputArmed`, which the host
persists with the rest of the topology — overturning its "never persisted, dies with the app" doc
comment. Sync-input surviving a relaunch is a behaviour change and is the price of the tab being one
object that every client and the host agree about.

**The close successor is the host's, so the project-section rule moves with it.** `plannedTabSuccessor`
picks MRU, else the neighbour inside the same PROJECT SECTION, else display order — that middle clause
is the `ed76f137` fix for the close-jumps-to-another-project bug, and it is not fixable client-side
once the host owns the close. So it is re-landed rather than surrendered: `TabOrderingEngine` (with the
pane → project-key precedence that feeds it) lives in `SlopDeskWorkspaceModel`, below both ends,
because `SlopDeskHost` cannot see `SlopDeskWorkspaceCore` and a second transcription host-side is
exactly how the bug comes back. `WorkspaceIntentApplier.apply` takes the pane → key lookup as a
parameter; the host document, the loopback and the client's optimistic overlay all feed it the same two
document cells (`pane/projectKey`, else `pane/cwd`) so all three pick the same tab.

So the successor RULE is unchanged. What the move actually changes is the ring it reads: the MRU is
host-owned and SHARED, so two clients closing the same tab land on the same tab, where two per-client
rings would have sent them to two different ones. That is the point of the phase, stated in the one
place a user would notice it.

### 2. The seam is opt-in, and the client never installs a document of its own

`WorkspaceChannelClient.send(intent:)` refuses anything that is not `.live`, and `.live` is published
only from inside the async `start()` run loop. Every store mutator is synchronous. So the cutover
turns ~430 synchronous call sites across ~100 test files into no-ops that compile, log nothing, and
fail the suite as "nothing happened" with no pointer to the cause.

`LoopbackWorkspaceDocument` answers that by BEING the host in-process: the same
`WorkspaceIntentApplier`, the same `encodeDiff` → `decodeDiff` round trip through the mirror's own
apply entry point, on the caller's turn. A differential test pins it against `HostWorkspaceDocument`
byte for byte, because the decision function is shared but the versioning around it is not.

**Nothing installs one by default, and that is the ruling.** A client that can rewrite its own
workspace with no host in the loop IS the locally-owned tree this phase exists to delete, and shipping
one as the default would make "the host applied my intent" and "I applied my own intent" the same
code path — a green suite with the workspace channel entirely broken. So it is reached by name
(`WorkspaceStore.attachLoopbackWorkspaceDocument()`), production builds its channel through
`liveWorkspaceChannel`, which has no document, and a client with no host keeps exactly one honest
outcome: it cannot change the layout.

**Frame order is result-then-document.** `WorkspaceChannelSession.drain` writes every queued
`intentResult` before the state frame, so an `applied` result arms its patch at `framesApplied + 1`
and the diff immediately behind retires it in the same turn. The loopback reproduces that order; the
opposite order leaves one inert patch shadowing host truth until some later intent sweeps it.

### 3. Two facts the cutover has to carry, found by measuring

**`spawnTab` and `splitPane` are not determined by their arguments.** `WorkspaceTreeOps.newTab` mints
the `TabID` itself, so the client's optimistic patch and the host's diff name different tabs for the
same intent. Ruling 1 of the Phase 5 entry — new object ids are PROPOSED by the client — covers the
pane and not the tab.

**Presence is drained by one task, not one per update.** A detached task per `updatePresence`
publishes in scheduling order, not issue order, and the host keeps the newest `presenceClock` and
ignores the rest — so a reordered burst leaves the roster showing a view the user has already left,
permanently, with nothing later to correct it.

### 4. The cross-tab gutter drop is a wider op 23, not a lost gesture

`dockPaneAtTabEdge` already carries `(sourcePaneID, targetTabID, edgeByte)`, and it already refuses
anything that does not land in the tab the client named. What it did not have was an applier that could
GET there: it ran the same-tab `WorkspaceTreeOps.moveLeafToRootEdge`, so the rail-drag MOVE of a pane
out of one tab into another tab's container gutter was refused on arrival. The fix is
`moveLeafToTabRootEdge`, which resolves the destination by tab id instead of by `activeTabIndex`;
`moveLeafToActiveTabRootEdge` delegates to it, and is the local gesture pointed at the active tab.
**No wire change and no golden change** — the args always said which tab. Accepting the loss would
have deleted a shipped gesture for more work than delivering it.

A destination in another SESSION stays refused. The prune and the insert are one session's business —
the pane's spec lives in `session.specs`, so a cross-session dock is a different op with a different
invariant to keep, and no gesture asks for one.

### 5. The GUI gates launch a real host and a throwaway workspace dir

`check-video.sh` ran only `slopdesk-videohostd`. Once the layout is the host's, the detached `.desktop`
pane the video seam mints is an object in a document that daemon does not have — the client would send
its intent nowhere and the gate would pass on a screenshot of an empty window. So the video proof
starts `slopdesk-hostd` too and points `SLOPDESK_AUTOCONNECT_PORT` at it, which is the TCP leg
`WorkspaceStore.videoTarget(from:)` already reads. The alternative — installing a
`LoopbackWorkspaceDocument` under automation — would make the GUI proof stop proving the shipping
path's layout, and installing one by default is rejected in §2 above.

Both gates give their daemon a throwaway `HOME` **and** a fresh `SLOPDESK_WORKSPACE_STATE_DIR`. The
client's `persistence: nil` under automation protected the developer's `workspace.json`; it protects
nothing once the client reshapes the HOST. Fresh, not merely private: `adoptWorkspace` answers
`rejectedStale` to a host that already has a workspace, so a reused dir would keep a stale layout and
the screenshot would prove the wrong thing.

### 6. What the cutover found once every mutator went through the applier

Six client rules turned out to live in the client. Each is now the applier's, because a client cannot
correct the host afterwards:

**A cascaded-away tab is as reopenable as a closed one.** `closeTab` filed the whole tab onto the ring;
`closePane` did not — so closing a tab's SOLE leaf silently cost the user their ⇧⌘T. It captures now,
through the same helper, when the pane it is asked to close is its tab's only leaf.

**Closing a BACKGROUND tab returns the session's own active tab.** Ahead of the MRU ring, because the
ring's head is where the user was BEFORE, which is not where they are now. Without it, dismissing a tab
you are not looking at moves your selection — the bug the index clamp used to cause.

**A closed tab outlives its session.** A session emptied by closing its last tab takes its id with it,
while the tabs it lost still hold the only copy of their panes' specs. So ingestion requires the
`tab/sessionID` back-pointer to be PRESENT but no longer to resolve, and `reopenClosedTab` lands an
orphan in whichever session is active rather than refusing it.

**`adoptWorkspace` is staged optimistically.** `pristine` is a fact about the HOST's own file and no
cell carries it, so a client asking `WorkspaceIntentApplier` "would this be accepted" can only answer
by assuming yes. `WorkspaceMirrorBox.stageIntent` therefore passes `documentIsPristine: true` and lets
a `rejectedStale` snap the patch away — which is what the pending layer is for. Refusing locally
instead would make op 0 unsendable by construction, and the automation bootstrap is its only caller.

**`canMutate` requires `.live`, not merely a channel.** The mirror is SEEDED with the restored tree at
`init`, so `topology != nil` the moment the store exists — a bootstrap armed on "there is a topology"
would fire before the subscription and be dropped by `send(intent:)`'s own guard, consuming itself.

**A tab with no active pane is unrepresentable.** The document's tab decoder repairs a missing focus to
the tab's first leaf. So the client's "looking at no pane" report is reached by having no workspace at
all — refused, or not yet subscribed — which is the state a client is actually ever in.

### 7. `followSessionFocus` is an OVERLAY on the projection, not a second tree

docs/45 §8.2 shipped the flag — persisted, ON macOS, OFF iOS — and nothing read it. Reading it is the
last thing the cutover owed, and it is the one place where "the layout is one value" has to bend: an
iPhone glancing at a build log must not drag a Studio's screen with it, and OFF is the shipped iOS
default, so the unfollowing path is not an edge case.

It is expressed the same way the divider drag already is — a device-local value the `tree` getter lays
over `workspaceMirror.topology`, keyed off the same `workspaceMirrorRevision` that both caches the
projection and invalidates every reader. `WorkspaceStore.DeviceFocus` holds one tab and, when the
navigation named one, one pane; `stageFocus(tab:)` / `stageFocus(pane:)` are the fork, and every focus
gesture — `selectTab`, `selectSession`, `focusPaneTree`, and the directional `moveFocusTree` — goes
through them, so nothing can grow a fifth path that ignores the flag.

Three things this shape decides:

**The overlay re-applies the applier's own op.** It runs `WorkspaceTreeOps.focusPane`, which is
literally what op 10 runs host-side, so an unfollowing device sees precisely what it would have seen
had it been following — including the zoom-exit rule, without which a local focus could land on a pane
the tab's shared zoom hides.

**It resolves at read time and is never reconciled.** A tab or pane another client closed simply stops
applying and host truth shows through, so there is no sweep to get wrong and no way for this device to
be stranded on a view of a thing that is gone.

**Turning following back ON clears it.** A surviving overlay would pin the device to a tab no other
client can see it on. That also means the only state in which one can be held is "not following", so
the overlay needs no second guard on the flag — one rule, checked in one place.

Presence is untouched by all of this and deliberately so: `currentWorkspaceView()` reports the
projection, which already carries the overlay, so an unfollowing client still publishes where it is
looking and the roster still names it. That is the whole difference between looking away and hiding.

Two consequences that fall out of putting the overlay under `tree` rather than beside it, both wanted:

**A LAYOUT gesture still lands where the user is pointing.** `splitActivePane`, `toggleZoomTree` and
the rest resolve their target off `tree`, so they name the pane THIS device sees — an unfollowing
phone splits its own pane, not the Studio's. The intent carries that pane's id, so the host applies it
to the right leaf and every client sees the split. Only FOCUS is device-local; the layout stays one
value, which is the line the whole phase draws.

**An unfollowing device does not feed `session/focusMRU`.** The ring is advanced by the `focusTab`
intent, so a phone that sends none contributes no history and the close successor is chosen from where
the FOLLOWING clients have been. That is the correct reading of §8.2 — a client that declines to move
shared focus has also declined to vote on it — and closing a tab remains a shared layout change either
way, so the phone's own view falls back to host truth when the tab it was on goes.

## Multi-client Phase 5b: what the projection owed the rest of the app (2026-07-27)

[docs/45](45-multi-client-state-sync.md) §7.2. A review round over the cutover above. Every finding
here has the same shape: `WorkspaceStore.tree` became a value nothing local has to touch for it to
change, and six things around it still assumed the opposite.

### 1. A document change reconciles the registry — the tree of intent moved without its table of liveness

`reconcileTree()` had 51 call sites and every one of them was a store MUTATOR. That was correct while
the store owned the tree: nothing else could change the leaf set. With `tree` a projection it is the
whole multi-client case that is missed — client A splits, client B's rail grows a row for a pane B has
no `LivePaneSession` for (blank, no PTY, no error), and a pane A closes leaves B's handle and its mux
channel up forever. It fires on the SINGLE-client path too, at every connect: the launch seed is
replaced wholesale by the host's own snapshot, whose pane ids this client has never seen.

So the mirror's change hook reconciles. Two rules make that safe:

**A reconcile already running suppresses it.** The diff clears the overlay of every pane it orphaned,
and each clear announces itself — without the guard the hook re-enters the pass that triggered it,
once per cleared pane.

**A document-driven pass does NOT acknowledge focus.** `clearActiveLeafCompletionBadge()` and
`refreshFocusedDoneSettle()` mean "this user has arrived at the focused pane", and a change another
client published is not this device visiting anything. Unread-completion is a per-DEVICE fact; running
those on a remote change is how a ✓ disappears before anyone here saw it.

### 2. With no document there is no layout, so nothing is written

`stop()` resets the mirror, and it runs on the way to EVERY re-subscribe — so `topology == nil` and
`tree` is a workspace of zero sessions for as long as the resubscribe takes, and forever against a
host that refuses the channel. Both writers read `tree`: the layout save and the document-fact cache.
A quit in that window replaced `workspace.json` with an empty workspace and `workspace-cache.json`
with an empty state — the layout and the cold-paint folder names gone permanently, for a condition
that is not an error at all.

The absence of a document is not an empty document. Both writers skip.

### 3. Op 26 `setPaneVideoTarget` — the mint is not the last word on a binding

**This is a wire addition, and `golden/golden_vectors.json` moved for it** (one appended op entry,
plus two new `workspaceIntentArgs` vectors; hand-merged, generated with no `SLOPDESK_*` set).

`spawnDetachedPane` was documented as the only op that can write `pane/videoTarget`, and the cutover
made `updateSpecLive` drop anything that was not an authored rename. Between them, the pane-rebind sink
— whose entire job is "persist every committed video endpoint so a relaunch re-streams the bound
window" — became a debug log line. The display switcher and the window re-pick both move a stream that
is ALREADY RUNNING: the document kept naming display 0 while the window showed display 1, so a relaunch
re-streamed 0 and ⌥⌘N on display 0 revealed the window showing 1 while ⌥⌘N on display 1 minted a
duplicate.

There is no client-side repair — a fact with no op behind it is one the next host frame erases. The op
carries the DERIVED title with it (the applier renames the pane to the new target's title unless the
user authored one) so the binding and the label can never disagree, and a zero-length target UNBINDS,
which stays distinct from bytes that fail to decode.

### 4. The device-focus overlay follows the object the device itself just made

§7 above ruled that the overlay is never reconciled — a tab another client closed simply stops
applying. That is right for a change this device did not ask for and wrong for one it did: the appliers
land a new tab, a split's new leaf and a reopened tab FOCUSED, and an overlay still naming the old one
undoes exactly that. On iOS, where not-following is the default, ⌘T grew a rail row the device never
switched to and a split left the keystrokes in the pane it was split off.

So a staged intent adopts the focus it moved, and the probe has two halves because the appliers move
two different things: `spawnTab` / `newSession` / `reopenClosedTab` change the ACTIVE TAB, while
`splitPane` / `closePane` / `reattachPane` leave it alone and focus a leaf inside whichever tab they
touched — which, on an unfollowing device, is the device's tab and not the host's. A gesture that moves
no focus at all (a divider drag, a rename) leaves the device exactly where it was looking, which is
what keeps §7's guarantee intact.

A device whose own tab went away with the change drops the overlay rather than keeping a dead `TabID`:
⇧⌘T restores a tab under its ORIGINAL id, so a stale overlay would silently come back to life with it.

### 5. The launch adopt is sent WITHOUT an optimistic patch

§6 above ruled `adoptWorkspace` optimistic, because `pristine` is a fact about the host's own file and
no cell carries it. That ruling stands for the automation bootstrap. It does not survive giving op 0 a
NORMAL-launch caller, which it needed: `stageAdopt` had no non-automation caller at all, so a user
upgrading with a six-tab workspace met a first-run host, got its single-pane default, and lost the
layout — uploaded nowhere, even though `documentIsPristine` means the host would have taken it.

Offered optimistically, the far more common REFUSAL (any host that already has a workspace, i.e. every
launch after the first) would flash the client's stale layout for a round trip — and, with ruling 1
above, spawn a shell for every pane in it and kill them all when the refusal lands. So the launch offer
goes out unstaged: nothing to roll back, a refusal costs one frame and changes nothing on screen, an
acceptance arrives as an ordinary document frame. Once per launch — a reconnect must not re-offer a
tree that describes the workspace as it was before every change made since.

### 6. Three rules that were counting the wrong thing

**The ⇧⌘T cue asks WHICH tab is on the ring, not how many.** `WorkspaceIntentApplier.capturing` trims
to `closedTabRingCap` right after appending, and the ring is host-persisted and shared — so the count
reaches 25 and never grows again, and every close from that moment on loses its undo affordance while
⇧⌘T keeps working.

**A re-tile exits zoom.** `WorkspaceTreeOps.applyLayout` cleared `zoomedPane` ("`select-layout` exits
zoom"); op 24 carries only ids and axes, so the applier preserved it. A zoomed tab renders one pane, so
the re-tile lands invisibly while the caller's cycle cursor keeps advancing underneath. The applier
clears it, which is where the rule belongs now.

**`tabFocusHistory` is deleted, not kept.** The close successor reads `topology.focusMRU`; the client's
ring had no reader left, and a test still pinned its exact contents. A pinned value that cannot affect
behaviour is worse than no test: the next editor reasons about the wrong MRU. The tests now assert the
document's ring, which is the one the close path actually reads.

### 7. A refused layout change is REPORTED, not silently swallowed

docs/45 §7.2 said "the UI disables mutation while the workspace channel is down", and nothing read
`canMutate`. Because `init` seeds the mirror, a store with a dead channel renders a complete,
normal-looking workspace in which every gesture is a no-op logged only behind
`SLOPDESK_WORKSPACE_DEBUG` — indistinguishable from a UI that ignored the gesture.

Disabling was rejected: the controls are the whole workspace (every divider, every tab, every pane),
graying them is a large surface for a transient state, and the honest problem is that the failure is
INVISIBLE rather than that it is possible. So `stage(_:_:)` fires `onLayoutChangeUnavailable` and the
app raises a transient chip beside the ⇧⌘T and jump cues it already has. A refusal ON THE MERITS — a
re-tile of a lone leaf, a reopen with an empty ring — stays silent: that is the document doing its job
and says nothing about reachability.

---

## Multi-client Phase 6: the read-only subscriber, and the phone that fits (2026-07-27)

Design: [45 — Multi-client state sync](45-multi-client-state-sync.md) §8.3, §8.4, §9 Phase 6. Shipped
behind `SLOPDESK_PANE_FANOUT` (`== "1"`, **default-OFF**). No wire change, no golden change: the whole
phase leaves `golden/golden_vectors.json` byte-identical and moves no unknown-type probe.

### 1. Read-only is a property of the SUBSCRIBER, never of the session

An observer (`channelClass == 2`) is one member of a `MuxChannelSession` that has other members. Two
things share the PTY with it and must keep writing: every ordinary member's own input relay, and
`writeRawForControl` — the `slopdesk-ctl` / orchestrator injection path, which is not a subscriber at
all. A session-level `isReadOnly` flag would gag the cockpit the moment somebody opened a read-only
view, breaking every scripted answer with no error. So the drop lives in `startInputRelay(for:)` and
nowhere else.

### 2. A dropped frame is STILL credited — this is the whole trap

Credit is granted at CONSUMPTION. A frame that is dropped without `noteConsumed` never returns the
window: the observer's sender parks after exactly one window and the channel dies silently, with no
error and nothing to grep for. It would present as "the read-only client froze after a while", on
hardware, weeks later. `testAnObserversInputIsDroppedButStillCredited` delivers more than a full
window so a build that drops-without-crediting cannot pass by accident.

The echo probe and `foldUserInput` ARE skipped with the write. `foldUserInput` is the Esc-cancel
unblock edge, so an observer's stray keystroke would clear another client's `.needsPermission` latch —
the supervision alert vanishes and nobody answers the prompt.

### 3. An observer never votes in the size fold, and the rule is structural

Passivity is applied inside `addResizeContributor`, not at the join call site, so every path that
re-resolves passivity (notably `reresolveSizePassivity` on a late workspace `subscribe`) keeps it. The
observer is still REGISTERED as an attachment with `contributes: false` — it genuinely holds the pane,
and publishing it is what lets a client name who IS clamping.

The same audit found `reresolveSizePassivity` addressing `primarySubscriberID` unconditionally: under
a fan-out, one session is named by N keys, so a phone's late subscribe would have marked the MAC's
contribution passive and handed the phone the vote it was denied. It now resolves the subscriber the
connection actually rides.

### 4. `MuxClientTransport`'s acquire hop was the missing half

`channelClass` has ridden `MuxChannelOpen` since the mux landed, and `ConnectionRegistry.acquire` and
`MuxNWConnection.openChannel` both took it with a default of 0 — but `MuxClientTransport`'s injected
closure was 5-arg and could not express it, so every pane opened as class 0 because that was the only
value the hop had. The widening is a Swift signature change inside `SlopDeskTransport`, not a wire
change. Anyone estimating this as "the field is already on the wire" measured the host half only.

### 5. VIEWERS and HOLDERS are different facts and the UI says both

`paneViewers` reads the roster's `clients` (`viewingPaneID`); `paneHolders` reads its `panes`
(`attachments`), joined to `clients` for a label. A client can look at a pane it does not hold and
hold one it is not showing. The join to a label is OPTIONAL and legitimately misses —
`slopdesk-client` opens no workspace channel — so an unlabelled attachment is NAMED (`another
client`), never force-unwrapped and never dropped: dropping it would make a CLI-held pane read as
unheld and make the resolved grid's arithmetic unexplainable.

### 6. The iOS letterbox SHRINKS, and never magnifies

A phone is size-passive host-side, so the grid belongs to whichever Mac clamped the fold. The surface
is framed at its NATURAL size for that grid and then transformed — sizing the frame to the scaled rect
would make the renderer derive a different grid from it, which is the phone reflowing to its own
window, the exact thing size-passivity exists to stop. Scale is capped at 1: magnifying a glyph grid
is blur, and a coding tool's text has to be exact.

Every input can legitimately be absent (no roster, no cell metrics, pre-layout), and each of those
renders FULL-BLEED — the honest ceiling the pane's other overlays already keep: an absent decoration,
never a wrong one. The geometry and the `120×40 · sized by MacBook Pro` readout are pure values in
`SlopDeskTerminal` so they carry the tests the iOS-only SwiftUI path cannot; `check-ios.sh` proves the
view type-checks.

### 7. The `attachedElsewhere` refusal is flag-conditional, not deleted

> **SUPERSEDED 2026-07-29** by "Multi-client fan-out is unconditional" at the end of this log. The
> flag is deleted, and the refusal with it — ungating PATH D makes the branch unreachable, not merely
> flag-off. What follows is the 2026-07-27 reasoning, kept as written.

docs/45 §9 said "delete it". It survives as the flag-OFF branch instead, and that is what keeps the
shipping path byte-identical: with the flag unset the JOIN route is unreachable, `subscribers.count`
never exceeds 1, the drain never leaves its inline single-send, and no outbox is ever built. It gets
deleted the day the flag flips default-ON — which needs hardware, and hardware has said nothing yet.

## Multi-client: two clients, watched (2026-07-28)

Design: [45 — Multi-client state sync](45-multi-client-state-sync.md) §9 Phase 5b. `docs/45` carried
one open item through six phases — "nobody has yet watched two real clients converge on one layout".
`scripts/check-multiclient.sh` is that observation, standing. No production code moved: the gate is a
script plus the contract tests that keep it honest.

### 1. The gate observes the CLIENT, not the host

The claim is "client B's view followed". Reading the host's `workspace-state.json` proves the host
applied the intent, which is the PREMISE — a gate built on it stays green through any client-side
regression that stops B rendering what it was sent. So each instance is asked what IT is showing,
over its own `SLOPDESK_CLIENT_SOCKET`: `slopdesk --socket … windows|tabs|panes` is served by
`WorkspaceControlBackend` off `WorkspaceStore.tree`, which IS the projection. `GuiGateLaunchContract-
Tests` asserts the host document file never reappears in the gate's code.

### 2. No test seam was needed, and none was added

The obvious move — an env var that makes a client dump its topology — buys production code for an
automation-only reader. The client-control socket already answers the same question through a
SHIPPING path, so a regression in the thing the gate reads is a regression a user would also feel.

### 3. The gesture is a real menu click

`Panes ▸ Split Right` through System Events, addressed by unix id (two same-named processes). That
exercises command → intent → host → fan-out → projection, which an env seam calling the store
directly would skip. The price is an Accessibility TCC grant for whatever terminal runs the gate; it
is named in the failure message, and the gate is already Aqua-only.

### 4. What converges is TOPOLOGY

Pane ids, owning tab, pane kind, tab order, per-tab pane counts. Titles and cwd are LIVENESS (§4.1) —
pushed on a pane's own control channel, which with `SLOPDESK_PANE_FANOUT` off only ONE client holds —
and focus is device-overridable on purpose (§8.2). Comparing them would pin flakiness as if it were
the contract.

### 5. The second client starts from a DIFFERENT layout, deliberately

Both instances launch with the same automation bootstrap, so B mints its own session/tab/pane, mounts
them, and has its `adoptWorkspace` refused by a host that already has one. Convergence from two
different starting layouts is a stronger claim than convergence from an empty one, and it is the only
shape that exercises the refusal path end to end.

### 6. Shells are counted LIVE, not cumulative

`N panes ⇒ N shells` is a statement about what is still running. The cumulative `shell … attached`
count legitimately includes B's refused launch pane and the pane a closed tab took with it — both
reaped. Counting log lines would pin a number that has no invariant behind it; counting the daemon's
children names the actual failure, which is a PTY nobody's layout claims.

It is REACHED then HELD, not read once. A single read the instant `converge` returns goes red on a
correct system under `SLOPDESK_PANE_FANOUT=1`: the transient PTY in §8 below is still alive at that
moment, because `converge` returns when the DOCUMENT DIFF lands and the reap waits on B's leaf
unmounting behind it. Waiting cannot hide the failure the census exists to catch — a leak is
permanent, so the deadline expires and the same message prints — and the hold that follows is what
stops a late re-dial slipping in behind the assertion.

### 7. Fan-out is asserted POSITIVELY, per pane

With `SLOPDESK_PANE_FANOUT=1`, "no `attachedElsewhere` refusals" is satisfied by a second client that
never tried to attach. Every pane in the final layout must appear in a hostd `joined live session …
as subscriber` line; only then does the absence of refusals mean anything.

### 8. One thing hardware said that no test had

Flag ON, closing a tab on client A makes client B spawn a fresh PTY for the pane that just died: B's
leaf re-dials in the window between the host's `channelClose` and the document diff that removes the
pane, and a pane channel naming a session the host no longer has is a SPAWN. Transient — the diff
lands, the leaf unmounts, the shell is reaped, and the live count is exact afterwards — and absent
with the flag off, where B holds no channel to re-dial. Recorded in [45 §9 Phase 6], not fixed here:
it belongs to the flag that is still default-OFF. **Fixed since** — and it was the reconnect campaign,
not the leaf: see "A pane the host retired is not re-dialled" below.

## The launch dial hold: a pane does not open a PTY under an unconfirmed id (2026-07-28)

Design: [45 — Multi-client state sync](45-multi-client-state-sync.md) §7.4 point 5. Hardware found
a client whose restored pane ids diverged from a non-pristine host's dialling its own ids anyway:
the host spawned a shell for each unknown session id, the `adoptWorkspace` came back
`rejectedStale`, and the client then projected host truth and abandoned what it had dialled.
Measured, one hostd and two launches: `client ['5C95FF8D','71673628','6573D268']` vs
`host ['11111111','22222222','33333333']` → **three panes on screen, SIX shells**. After the hold,
same script, **three**.

### 1. It is a bug, not a tradeoff — because SHOWING and DIALLING are separable

The framing that nearly made this a design decision was that any fix "regresses the case
`runArmedLaunchAdoptIfPossible` exists for: the first connect to a genuinely new host". That is only
true of fixes that touch the OFFER — host-scoping `workspace.json`, or refusing to propose. The
offer is not the problem. What the optimistic patch buys is the layout on screen in the first frame,
and that is untouched here: the panes render, in their tabs, with their titles and cached folder
names. What it cannot buy is a PTY, because opening one is the single act on this path that a
`rejectedStale` cannot take back. So the hold is on the DIAL alone, and the pristine-host case keeps
everything it had.

### 2. The hold waits on the ADOPT'S OWN intent id, not on "some patch is pending"

`adoptWorkspace` is the one op whose verdict a client genuinely cannot predict — `documentIsPristine`
is a fact about the host's file that no cell carries, which is why `WorkspaceMirrorBox.stageIntent`
hardcodes `documentIsPristine: true` for the optimistic run. Every other pane-minting op (split, new
tab, reopen) is pre-checked against the same applier the host runs, so its ids are as good as
accepted and its panes dial on the frame the user asked for — Phase 5 ruling 1 survives intact. So
`send(intent:args:intentID:)` takes the id, `runArmedLaunchAdoptIfPossible` mints and keeps it, and
`isPending(_:)` answers the gate. Waiting on `pendingIntentCount == 0` instead would have let any
gesture in that window extend the hold for reasons unrelated to it.

### 3. The id is claimed BEFORE the stage, and that ordering is the whole fix working

Staging announces itself on the mirror, and the mirror's change hook re-runs the gate. An id recorded
after `stageAdopt` returns leaves the gate reading "no offer outstanding" for exactly the turn in
which the offer became a prediction — and the fan-out inside that turn dials every restored pane.
`beginPending` runs before the announcement, so an id claimed first is already answerable when the
re-entrant refresh fires. This was caught by the headless test, not by reading the code.

### 4. Bounded, and every terminal state opens it

A hold with no release is worse than the churn: a window of panes that never connect. So it opens on
`rejectedStale`, on `applied` + the frame behind it, on the `pendingTimeout` backstop (a host that
accepted and died), on `box.reset()`, on a channel that answers `refused` or `closed`, on a store
with no channel at all, and on the in-process loopback (whose document adopted this very seed). The
gate is a STORED, observed property because its inputs are `@ObservationIgnored` launch state and a
plain-class channel state — a computed one would never invalidate the SwiftUI body that keys on it.

### 5. Released by a store fan-out, not only by the leaf that re-renders

`TerminalLeafView`'s connect task is keyed on `dialTaskKey`, which moves `nil → pane` on release, so
a mounted leaf re-fires. That alone would leave anything SwiftUI has not got to — a satellite window,
a leaf mid-mount — waiting for an unrelated nudge. So the release also calls
`redialDisconnectedPanes()`, which no-ops on a healthy channel. It also makes the property provable
with no view in the process, which is how it is tested.

### 6. The AUTOMATION bootstrap is deliberately NOT held

`bootstrapTree` also ends in `stageAdopt`, and its refusal has the same shape — `check-multiclient.sh`
engineers exactly that for its second client, and its §6 note already accounts for the throwaway
shell. It is left alone: the bootstrap runs only under `SLOPDESK_AUTOCONNECT_*`, which no user sets,
so holding it would buy a round trip of latency and regression risk in two load-bearing GUI gates for
zero user-facing benefit. The boundary is `pendingLaunchAdopt`, which the bootstrap clears when it
takes over the launch.

### 7. The gate got a phase, and the fixture that feeds it is DERIVED

`check-launch-restore.sh` phase C relaunches with a layout whose pane ids the host has never seen and
asserts that not one of them reaches the host — plus, in `hold_steady`, that the whole log's
`attached for pane` count never leaves the pane count, which is the number that went to six. The
divergent layout is derived from the committed fixture by rewriting every UUID (`uuid5`, so runs are
reproducible) rather than committed beside it: a second file is a second thing to keep in step, and
the day it drifted the gate would pass while testing a different shape. Disjointness and pane count
are asserted, so a derivation that quietly produced the same ids fails loudly.

### 8. The gate's own hostd HOME is now wiped between runs

Found while running phase C: the scrollback JOURNAL lives under `<Application Support>` off HOME, and
the gate reset only `SLOPDESK_WORKSPACE_STATE_DIR`. With the fixture pinning the pane ids, run N+1
inherited run N's transcripts and phase A's "cold launch against a pristine host" replayed bytes from
a session it never had. That is the one input that differed between two otherwise identical runs, and
one of them went red. Wiping it is the gate keeping the promise its own comment already made.

## The fan-out laggard soak: the producer bound does not survive a shrink (2026-07-28)

Design: [45 — Multi-client state sync](45-multi-client-state-sync.md) §8.6, §10 open question 2.
`SLOPDESK_SUB_LAG_BYTES` and `min(lastAckedSeq)` retention shipped with the fan-out but had never
been watched under a real slow subscriber. `scripts/soak-fanout-laggard.sh` is that soak: a real
`slopdesk-hostd`, real `slopdesk-client`s, a real PTY, and a laggard frozen with `SIGSTOP` — which
stops it reading its socket and acking in the same instant, the way a backgrounded phone stops.

### 1. What the soak confirmed, with numbers

At the shipped `SLOPDESK_SUB_LAG_BYTES = 32 MiB`: retention held **8.4 MB / 113,359 lines** for the
frozen laggard and it received every one of them, in order, exactly once, on resume. The fast member
took **134.2 MB / 1,813,753 lines** — contiguous, no duplicates — *while* the laggard was frozen, so
neither the drain nor the read loop is serialised behind a parked member. Eviction fired on the
laggard and only the laggard (`pane subscriber 1: evicted`), the shell survived it, and the evicted
client reconnected to a rendered screen. Every property docs/45 §8.6 claims, on the shipped binaries.

**What it cannot settle is the CONSTANT.** On loopback the entire 134 MB moves in ~20 s, so 32 MiB of
lag accumulates far faster than any human-scale "my phone was asleep" interval. 32 MiB remains an
unvalidated first guess pending a cellular link; the soak validates the machinery around it.

### 2. What it broke: "the last subscriber is gone" ≠ "nobody is consuming"

The producer bound is `PausableQueueGate`, and it counts **enqueued-not-yet-sent** bytes. On the
inline path that is exact: the drain parks *inside* `MuxSubChannel.send`, the out-FIFO fills to
`hostQueueCapacityBytes` (64 KiB), the read loop stops, and the kernel PTY buffer backpressures the
shell. Under fan-out the drain must hand each frame to per-member outboxes and dequeue immediately —
a serial `for sub in subscribers { await sub.data.send(…) }` would give every member head-of-line
over every other — so `outstanding` returns to zero on every frame and **that source can never assert
again, for the rest of the pane's life**. `fanoutActive` is cleared only by `rebindRelay`, which runs
off a set that has EMPTIED; a pane that shrinks from two members to one while LIVE keeps the fan-out
shape forever. And eviction cannot cover the gap, because it never takes a pane to zero members.

Measured as an A/B inside one hostd — a control pane that never fanned out, a test pane that fanned
out and then lost its second client, both frozen at the same instant, both asked for 44.4 MB: the
control's shell blocked after 64 KiB and was **still blocked minutes later**, while the test pane
delivered **44,400,067 bytes** into host RAM with nobody reading. Same process, same shell, same
generator. Two clients ago is enough to lose the bound permanently, and the laggard eviction this
work exists for is one of the ways a pane gets there.

### 3. The bound is re-derived from the FASTEST member, not restored by un-latching the flag

Flipping `fanoutActive` back on a live shrink is the obvious fix and it is wrong: the surviving
member's outbox sender may be mid-batch, so the drain resuming inline sends would interleave with it
and deliver frames out of order. Quiescing the sender first is worse — it is parked on a credit
window, and cancelling it drops the batch, which is byte loss.

So the gate gains a THIRD pause source, OR-composed with the other two under its one lock: bytes
sequenced that not even the fastest member has put on the wire, `retainedBytes(above:
max(lastSentSeq))`, against the same `BoundedQueuePolicy.capacity` so the attached ↔ detached re-size
still comes from one constant. The frontier is a **MAX**, which is the whole difference between this
and "the slowest member": one parked phone can never assert the pause while a Studio is still
draining — that member's cost stays `SLOPDESK_SUB_LAG_BYTES`'s problem. A pane nobody is draining
pauses exactly where the inline path always did.

`lastSentSeq` is advanced per MESSAGE, not per batch, and that is load-bearing: once this source has
paused the read loop there is no producer left to recompute anything, so a sender's own progress is
the only thing that can resume it. Batch granularity would leave the pane waiting for the very PTY
byte the pause is preventing.

### 4. Inert wherever it must be

The source keys on a member having an outbox SENDER, not on a flag or a member count. Nothing calls
`startDataSender` outside the two fan-out paths, so with `SLOPDESK_PANE_FANOUT` unset the frontier is
empty, the backlog is 0, and the shipping default is byte-identical. `rebindRelay` builds its
returning member without a sender, so the whole detach/reattach sequence — including a cold reattach
still pushing a 64 MiB detached backlog — is untouched. `detach()` empties the set and already
recomputes, so the detached "output while away" budget is not clipped by a stale frontier.

The transition from inline delivery to an outbox seeds the member's frontier at the HEAD: everything
through it has already reached that member, and a zero would read as "has shipped nothing" and pause
the read loop on every join. A joiner's seed also claims what the drain fanned into its outbox while
its snapshot was on the wire; that optimism is bounded by one gate capacity and self-corrects on the
next frames, which is cheaper than threading an exact watermark through the join.

## A pane the host retired is not re-dialled (2026-07-28)

Design: [45 — Multi-client state sync](45-multi-client-state-sync.md) §9 Phase 6. The transient
recorded there — "closing a tab on client A makes client B spawn a fresh PTY for the pane that just
died" — is closed. `SLOPDESK_PANE_FANOUT=1 scripts/check-multiclient.sh` had it in its own log every
run: four panes, **five** `attached for pane …` lines, one uuid appearing twice.

    mux channel  7 (conn …ADCA27): joined live session 5AD35312… as subscriber 1
    mux channel 11 (conn …ADCA27): shell /bin/sh (pid 75883) attached for pane 5AD35312…

### 1. The window is real, and it belongs to the HOST's own ordering

`HostServer+Workspace` answers an applied `closeTab` in a fixed order: `reapPanesRemovedFromTopology`
(a `channelClose` to every subscriber) and only then `reconcileWorkspaceDocument()` (the frame that
removes the pane). Client B therefore learns the channel is dead one round trip BEFORE it learns the
pane is gone. Client A never sees the window because its optimistic patch removed the pane on the
frame the user clicked, so its session was already torn down `deliberatelyClosed` when the host's
close arrived. Reordering the host would not fix it either: the two facts ride different channels and
land on different client tasks, so their arrival order is not the host's to promise.

### 2. It was never the leaf, and that is why a leaf-level gate would have been theatre

The obvious reading — "B's leaf re-dials" — does not survive reading the code. The leaf's connect
task is keyed on `dialTaskKey`, which moves only on the pane id or `panesMayDial`, and neither moves
here; and its body routes through `ConnectionViewModel.connectIfNeeded()`, which returns on
`.reconnecting`. The dial came from the pane's own `ReconnectManager`: the peer `channelClose` ends
the inbound stream exactly as a link failure does, `handleStreamEnded` yielded `.disconnected`, and
the campaign's first attempt fires with no backoff at all.

### 3. The discriminator has to come from the MUX, because it is gone by the time anyone can ask

Above the transport a retirement and a drop are the same event: a stream that ended. Only
`MuxNWConnection` still holds the difference, so the `channelClose` arm marks the sub-channel
(`MuxSubChannel.peerCloseReason`), `MuxClientTransport` reports it as `hostCloseReason`, and
`SlopDeskClient` records it BEFORE it yields the event — the `childExited` ordering, so every
subscriber reading the mark on that `.disconnected` sees it already set. (The mark starts life as a
bool and becomes a `MuxCloseReason` on 2026-07-28, below — the same seam, one level finer.)

Keyed on the FRAME, never on the resulting state. A REFUSED `channelOpenAck` also resolves to
`.closed` and also finishes the sub-channel, and it is not a retirement — it is a verdict on an open
this side is still making (`attachedElsewhere` is the shipped one), whose campaign must keep running.
`MuxPeerCloseMarkTests` pins both, and the refusal case goes red the moment the check is relaxed to
the state.

### 4. Terminal for the SESSION, not just for the campaign

There are three dial paths and gating one only moves the spawn. `ReconnectManager` gates on
`isHostClosed` beside `isPaused`/`isClosed`/`isExited`; `SlopDeskClient.connect` refuses outright,
which is the enforcement point at the one call that opens a channel; and `ConnectionViewModel`
carries its own mirror so `connectIfNeeded()` — the leaf's remount task AND
`redialDisconnectedPanes()` — returns. The mirror is needed because `connect()` builds a NEW client:
a client-level guard alone is invisible to the path that replaces the client.

An EXPLICIT re-dial clears it. The user asking for a shell on this pane is a decision this client is
entitled to make; what it must not do is make it automatically, a round trip before it learns the
pane is gone.

**Scope (2026-07-28, below).** The `connectIfNeeded()` mirror is `retiredByHost` and answers only the
REAPED pane. The eviction close latches `evictedByHost` instead, which gates the campaign and the
status but NOT `connectIfNeeded()` — see §6.

### 5. The status is `.disconnected`, because the campaign it would be waiting for is gated off

Leaving the fold at `.reconnecting(attempt: 0)` would have produced exactly the frozen dot this repo
keeps closing elsewhere: a spinner for a retry nobody is making. A host close reads as deliberate in
the fold — it IS deliberate, decided at the other end. `observeEvents` asks the client once, on
the `.disconnected` edge, so the fold stays synchronous and every other event skips the hop. Both
closes answer this the same way; there is no campaign behind either.

### 6. It covers the EVICTION close too, and that is the right answer, not a side effect

`wireSubscriberEviction` is the other place the host closes a pane channel: a laggard removed to
protect the session. An instant re-dial there re-joins to be evicted again — a churn loop that costs
the host a state transfer each time. Both closes mean "your attachment is over, by host decision",
and in both the recovery is an explicit re-dial or the app-connection fan-out, not a reflex.

**That last sentence names a recovery §4's guard disables — corrected 2026-07-28, below.** The
fan-out runs through `connectIfNeeded()`, which §4 gates, so an evicted client had neither recovery.
The eviction close now says so on the wire and only the reap latches the `connectIfNeeded()` guard;
the campaign stays gated for both, which is the churn this section is actually about.

### 7. The gate stops tolerating it, and gets an assertion a churn cannot outlive

`check-multiclient.sh` had been taught a 20 s settle because the spawn was transient and a live
census could only be told to wait it out. A live count is the wrong instrument for something that
dies: 7a now asserts that no pane uuid appears twice in `attached for pane …`, which is written down
permanently and passes no settle. Proven red by neutralising the three gates and re-running the flag
on: the shell census still said "2 pane(s), 2 live shell(s) ✅" and 7a failed by name. The settle
drops 20 s → 4 s, which is now sized for the only thing left in it — the kernel collecting a PTY
child the host killed before it broadcast the diff.

## An evicted subscriber can come back; a reaped pane cannot (2026-07-28)

Amends the ruling above: its §6 says an evicted client recovers by "an explicit re-dial or the
app-connection fan-out", and its §4 gates `connectIfNeeded()` — which IS the fan-out
(`WorkspaceStore.handleConnectionEstablished()` → `redialDisconnectedPanes()` →
`ConnectionViewModel.connectIfNeeded()`). So under `SLOPDESK_PANE_FANOUT=1` a client that lagged past
`SLOPDESK_SUB_LAG_BYTES` was evicted, kept the pane on screen — `leavePaneChannel` drops only that
client's registration, so the topology never loses it — and had exactly one way back: the user.
For the process lifetime, nothing else could dial it.

### 1. Retirement and eviction are opposite facts, and only the host knows which

A reap means the PANE is gone: its session id stops existing, so re-opening the channel is a fresh
login shell for a row that is one round trip from leaving the layout. An eviction means only the
ATTACHMENT is gone: the shell is still running, the other members still hold it, and this client's
topology still names it. The first must never be dialled again; the second is the only thing that
CAN dial itself back.

Above the transport both are one stream ending, and after an eviction nothing further is ever said —
no document frame follows, because nothing about the layout changed. So the fact has to ride the
close: `channelClose` gains an optional `[UInt8 reason]` (`MuxCloseReason`, docs/20 §8.3.2), and
`MuxSubChannel.peerCloseReason` carries it up through `MuxClientTransport.hostCloseReason` to
`SlopDeskClient.hostChannelCloseReason`.

`.retired` is the ABSENT body — the empty-bodied close every peer already sends — so the default path
stays byte-identical and only the eviction costs a byte. And a close always CLOSES: the reason is
advice about recovery, never permission to skip the teardown, so an absent body and an unrecognised
byte read the same conservative way (`.retired`, which withholds the automatic re-dial) instead of
throwing and stranding the channel open with its PTY.

### 2. The campaign is gated for BOTH; only `connectIfNeeded()` discriminates

This is the split the previous ruling collapsed. `ReconnectManager` asks `isHostClosed` and never the
reason — an immediate retry is wrong for a reap (a spawn) and wrong for an eviction (it re-joins to
be evicted again, billing the host a state transfer every lap). `SlopDeskClient.connect` refuses for
both, because THIS client instance is spent either way.

`ConnectionViewModel` is where they part. `retiredByHost` gates `connectIfNeeded()`; `evictedByHost`
does not. What that admits is precisely two events: the app-connection fan-out, and the leaf's
connect-on-remount when the user returns to the tab. Neither is a reflex — each is a one-shot,
client-level transition, and the fan-out in particular fires exactly when this client has just proven
it can hold a connection again. Recovery is an EVENT, not a retry.

### 3. The status stays `.disconnected`, and that is not a lie

The alternative ruling — eviction is terminal until the user acts — would have obliged the UI to
render the pane unreachable, because a pane drawn as live that can never reattach is a lie. It is not
the answer taken: the recovery above is real. But the pane still reads `.disconnected` between the
eviction and that recovery, because no campaign is running and `.reconnecting` would be the frozen
dot this repo keeps closing. `.disconnected` is what a drop with no retry behind it actually is, and
it is the state both the fan-out and an explicit Reconnect act on.

### 4. Proven where it can go red

`EvictedSubscriberRedialTests` drives the real `LivePaneSession` → `SlopDeskClient` path: the fan-out
recovers an evicted pane (red before the split — one channel, timed out waiting for two), the
campaign still does not (the control that keeps it from becoming churn), and the reap is still left
alone in the same rig. `HostServerCloseReasonTests` pins the reason at its origin over a real mux
loopback, so the one line in `wireSubscriberEviction` cannot be dropped silently; `MuxPeerCloseMarkTests`
and `MuxEnvelopeCodecTests` pin the wire, including that the default close is still an empty body.
`scripts/soak-fanout-laggard.sh` remains the proof against a real PTY and a real SIGSTOPped laggard.

## Multi-client fan-out is unconditional (2026-07-29)

Supersedes "Multi-client Phase 6 §7 — the `attachedElsewhere` refusal is flag-conditional, not
deleted" (2026-07-27) and discharges docs/45 §9 Phase 6 correction #1, which held the deletion until
"the day the flag flips default-ON". The ruling: multi-client sync is a first-class, always-on
feature — tmux and zellij do not ask permission to share a session either — so it ships with **no
toggle at all**. `SLOPDESK_PANE_FANOUT` is deleted: the environment variable, the
`HostServer.paneFanoutEnabled` property, the init parameter, and both guards it fed.

### 1. The `attachedElsewhere` refusal is not conditional, it is unreachable

Ungating PATH D does not merely make the refusal rare, it makes it dead, and the difference is worth
writing down because a "flag-off branch" that survives as dead code is how a deleted feature comes
back. `attachedElsewhere` was `joining == nil && liveElsewhere != nil`. With the flag gone, `joining`
is assigned from exactly the condition `let live = liveElsewhere`, so `liveElsewhere != nil` implies
`joining != nil` and the conjunction is unsatisfiable.

The step that had to be read rather than assumed is `registerJoiningKeyLocked`, because a registration
that could FAIL would resurrect the refusal under a new name. It cannot: it returns a non-optional
`MuxSubscriberID`, its body is `reserveSubscriberID()` plus two dictionary writes, and that resolves
to a post-incremented counter with no bound, no throw and no early return. There is no
registration-failed path for the refusal to survive as, so the local, the branch, and the comment
block explaining why the branch was not deletable all go.

One refusal on a live sessionID remains, and it is a different fact at a different time:
`performJoin`'s `joinSubscriber` returning nil — the pane emptied or the joining link died while the
host was composing its state transfer. It fires AFTER the accept ack, unregisters the key, and drops
the resize contributor. Deleting the exclusivity refusal does not touch it.

### 2. The detached-store claim needed a real guard, not a substitution

The one edit in this change that is not mechanical. The claim gate read `!attachedElsewhere`;
substituting the now-constant `false` would let a JOINING open also enter `store.claim`, and a hit
would have `muxSessions[key] = session` overwrite the registration `registerJoiningKeyLocked` wrote
one statement earlier — the joiner's key naming the CLAIMED session while `muxSubscriberIDs[key]`
names a member of the JOINED one. That is unreachable today only because a live session is never
also in the detached store, which is an inference about the store, not a stated invariant of this
critical section. It is written as `joining == nil`, so the mutual exclusion is in the code.

### 3. What the deleted refusal actually protected, and what now proves it

"One attachment per sessionID" was never the point; one SHELL per sessionID was. A second
`channelOpen` falling through to `spawnFreshShell` meant a second `openpty()` + `fork()` under one id
and `claimJournal` rotating the incumbent's journal writer out mid-session. The JOIN route is what
makes that impossible, so the test that pinned the refusal is inverted into the narrower claim that
survives it: `SubprocessE2ETests.testASecondClientJoinsTheLiveSessionAndForksNoSecondShell` counts
`/bin/sh` children of the real hostd pid **out of the process table** before and after the second
client attaches, and requires the same single pid.

Counted rather than inferred, because a host that answered the second open by forking again would
satisfy every byte-level assertion in `testTwoClientsShareOneRealPTY` — both clients would see a
working shell, their own — and still be broken. `comm` is matched as `-sh` as well as `sh`: a pane's
shell is a LOGIN shell, so `argv[0]` carries the conventional leading hyphen.

### 4. The gate stops being able to run blind

`scripts/check-multiclient.sh`'s step 7b was conditional on the flag, which made the fan-out
assertion optional in exactly the runs that did not set it — a gate that can pass without observing
the feature it exists to check. It is unconditional now. Its refusal grep goes with it rather than
staying: the log string it searched for is deleted, so the check could only ever pass vacuously, and
a tautological assertion in a gate is worse than no assertion because it reads like coverage. The
`SLOPDESK_PANE_FANOUT` the script passed to each CLIENT process was already dead — no client-side
code ever read the variable.

### 5. What is tuning and stays

`SLOPDESK_SUB_LAG_BYTES` (default 32 MiB, deliberately below the 64 MiB offline gate) and the
`min(lastAckedSeq)` retention fold are NOT feature toggles and are untouched. Neither was ever gated
on the flag: `evictLaggards` skips a one-member subscriber set on its own, so a lone subscriber is
never evicted because eviction requires two or more members — not because the fan-out was off.

### 6. No wire change, no golden change

`paneFanoutEnabled` appears in no encoder or decoder. `MuxChannelClass`'s raw values are untouched
and the `channelClass` byte has been on the wire and golden-pinned since the mux landed; only its
ROUTING moves. `golden/golden_vectors.json` is byte-identical.

## The workspace document is unconditional (2026-07-29)

Supersedes both "`SLOPDESK_WORKSPACE_DOC` stays default-OFF, and the client is not allowed to need
it" (Multi-client Phase 5b, 2026-07-27) and "`SLOPDESK_WORKSPACE_DOC` flips default-ON on BOTH ends
in the SAME commit" (Multi-client Phase 5b, 2026-07-27), and closes docs/45 §10 open question 1. The
companion to "Multi-client fan-out is unconditional": multi-client sync is a first-class, always-on
feature and ships with **no toggle at all**. `SLOPDESK_WORKSPACE_DOC` is deleted — the environment
variable, `HostServer.workspaceDocEnabled` (property, init parameter, both guards),
`WorkspaceChannelClient.isEnabledByDefault`, and its two conjuncts.

### 1. A switch whose off position is a broken product is not a switch

The 2026-07-27 coupling ruling described the off position exactly, and describing it is what settles
it. A host with the flag off answers `sendOpenAck(accepted: false)`; the client publishes
``WorkspaceChannelClient/State/refused`` and never retries, because a refusal is a definite answer
rather than a transient failure; `topology` stays `nil`; `stageIntent` returns `nil`, so every
mutation is a silent no-op that compiles. What the user gets is a blank window with no error
anywhere. There is no configuration in which somebody wants that, and a flag with one usable position
is a coupling hazard with a settings-shaped disguise — the two ends had to move in one commit
precisely because the mismatch is undiagnosable from the UI.

The "flag gates a TRANSPORT, so nothing on the render path may depend on it" rule from the earlier
entry is not repudiated; it was overtaken. Once `WorkspaceStore.tree` became a projection of
`workspaceMirror.topology`, the render path DOES depend on the channel, and the answer stated there
was to flip the flag rather than keep a tree-owning path beside the projection. Removing it is that
answer taken to its end.

### 2. Only the flag's share of the optionality goes

`HostServer.workspaceDocument` was Optional for exactly one reason — a single ternary on the flag —
so it becomes non-Optional and `openWorkspaceChannel`'s flag-off refusal arm goes with it as
unreachable code.

`HostServer.workspaceStore` stays Optional, and this is the distinction the change turns on:
`HostWorkspaceStore.make(...)` returns `nil` when Application Support cannot be resolved, and
`installWorkspaceDocument` has a live degraded arm for it that mints a fresh default each start and
keeps `pristine` true. A host that cannot persist still serves a workspace. Only the `: nil` arm of
the flag's ternary is deleted; the `?` on the type, `workspaceStore?.flush()` in `stop()`, and the
injected `workspaceStore:` init parameter are all untouched.

Also explicitly not dead: `State.refused` and `sendOpenAck(accepted: false)` for `channelClass == 1`,
which a second workspace channel on one mux connection still produces (two subscribers behind one
link would each keep their own acked base for the same viewer, and the roster would show one device
twice). `testASecondWorkspaceChannelOnOneConnectionIsRefused` is what keeps that path pinned.

### 3. "No workspace channel means CONTRIBUTES" survives, minus one clause

`sizePassiveForConnection` returning `false` for a connection with no workspace channel is unchanged.
Its populations are: the shipped `slopdesk-client` CLI, which can only ever open `channelClass` 0 or
2; the transient window in which a GUI client has opened pane channels but its subscribe has not
landed, which is what `reresolveSizePassivity(connectionID:)` exists to close; and any peer that does
not know the class. The flag-off client is struck from that list and nothing else about the rule
moves.

### 4. What the removal costs, named rather than discovered

Every host unit test that passed `workspaceDocEnabled: false` did so to stop `HostServer.init` from
constructing a `HostWorkspaceStore` at the developer's real Application Support path. With the
argument gone they all construct one. That is inert as the suite stands — no XCTest calls
`HostServer.start()`, so `installWorkspaceDocument()` and therefore `store.load()` never run, and
`stop()`'s `flush()` returns early with nothing pending — but it is a live trap for the next test
that adds a `start()`.

So the standing rule from the Phase-5 entry is restated wider: **any test that calls
`HostServer.start()` must inject a `workspaceStore:` or point `SLOPDESK_WORKSPACE_STATE_DIR` at a
scratch directory.** The construction is free; reaching disk is not.

### 5. Proven by inversion, and by an env read that must stay inert

`testTheFlagOffRefusesTheChannel` is inverted, not deleted:
`testTheWorkspaceChannelIsServedWithTheEnvironmentSetToZero` sets `SLOPDESK_WORKSPACE_DOC=0` in the
process environment, builds the rig under it, and requires an accepted open AND a real snapshot. It
is red before the change and green after, and it stays red if anyone re-introduces an env read —
which a constructor-argument test could not do, because after the change there is no argument to
pass. Deleting the test instead would have left the suite identically green on both sides of the
change, which proves nothing.

### 6. No wire change, no golden change

`workspaceDocEnabled` appears in no encoder or decoder, and the golden generator reads no
`SLOPDESK_*` variable. `MuxChannelClass.workspace`'s raw value `1` and the type-17/37 envelopes are
untouched — only whether the host is willing to route the class, which it now always is.
`golden/golden_vectors.json` is byte-identical.

### 7. What `make check` still cannot see

Green here proves the removal compiles and the unit contracts hold. It does not prove two clients
converge — `scripts/check-multiclient.sh` (Accessibility TCC, unlocked Aqua) and
`scripts/check-launch-restore.sh` are the only gates that reach the shipping workspace-document path,
and neither runs under `make check`.

## The dial hold is about PROVENANCE, not about the launch (2026-07-29)

Design: [45 — Multi-client state sync](45-multi-client-state-sync.md) §7.4 point 5. Extends "The
launch dial hold" above, which shipped keyed on one launch's `adoptWorkspace`. Multi-client sync is
now unconditional, which makes the divergent-id churn the difference between a feature and a
liability: it fires precisely when a client meets a host whose document it has not seen.

### 1. The launch was one instance of the rule, and keying on it left the rest reachable

The hold released the moment the launch offer was answered — `pendingLaunchAdopt`/`launchAdoptIntentID`
are per-launch facts — so a user who connects to a SECOND host inside one app run landed in the
identical state with none of the launch's markers: the tree on screen is host A's document, host B
has published nothing, and every pane id in it is unknown there. `HostServer` spawns a fresh PTY for
any unknown non-zero session id (PATH B, and it must — the client mints split/new-tab/reopen ids and
dials them ahead of the host applying the intent, Phase 5 ruling 1), so the establish fan-out spent
one shell per stale id and B's own document then replaced the layout and abandoned them.

Measured headlessly on the `LaunchDialHoldTests` rig — a real `WorkspaceChannelClient`, real
`LivePaneSession`s, three panes settled at host A and the app pointed at host B:
**six channels for three panes**, the same number hardware produced at launch. After the fix, three.

So the rule is stated once, about provenance: *a pane may dial an id at the host that named it, and
nowhere else.* `dialConfirmedHostKey` is the `host:port` whose own document frame last folded;
`panesMayDial` holds while it differs from the committed target. The launch arm is unchanged and
byte-identical — before any host frame there is no confirmed key, so a cold launch holds for the same
reason it always did, and the nine pre-existing pins in that file are the regression proof.

### 2. Stamped on the FOLD, never on the mirror merely announcing itself

`WorkspaceMirrorBox.onChange` fires for optimistic patches, fast-path pushes and presence rosters as
well as for document frames. Between `commitConnectionTarget(B)` and the re-subscribe that answers
it, the mirror still holds host A's document — so a stamp driven by the hook would file A's layout
under B's name and open the gate on the spot. `noteFoldedDocumentProvenance()` therefore gates on
`documentFramesApplied` MOVING, and skips `seedEpoch` (the store's own seed is the question, not an
answer). A `reset()` takes the count to zero, which is exactly right: the subscription that vouched
for those entries is gone.

### 3. `commitConnectionTarget` is the one place that can see it, and it already runs first

`AppConnection` commits the target before `establish()`, so the hold is in place before the
connection reports up and before `handleConnectionEstablished()` fans out. That function's two calls
are also reordered to open the subscription BEFORE the redial. The order settles nothing on its own
(both are asynchronous) — what settles it is the hold — but asking which panes exist before asking
for them is the rule this whole class of bug lives in, and the previous order stated the opposite.

### 4. Every arm is bounded, including the one that was not

A subscription the host ACCEPTS and never publishes on stays `.opening` forever: `.live` is published
only when a frame folds. Nothing bounded that arm, so a host that routed `channelClass 1` and then
went quiet left `panesMayDial` false for the life of the process — a window of panes that never
connect, which §4 of the entry above already ruled is worse than the churn. `paneDialHoldBackstop`
(one `pendingTimeout`, 3 s) is that release: armed while a hold stands, cancelled by any answer, and
re-armed in full at a second host rather than inheriting the first one's remainder. On expiry the
behaviour degrades to what it was before the hold existed — bounded churn beats an unbounded hold.

### 5. A reconnect to the SAME host is still not held

`testAReconnectIsNotHeld` pinned exactly the claim that left the hole open, and it was right about
its own case: after a wifi flap the panes on screen came from that host's own last frame, so their
ids are confirmed and a second round trip would be latency for nothing. It is SPLIT, not deleted —
`testAReconnectToTheSameHostIsNotHeld` keeps it (now committing a target, so it is no longer vacuous)
and `testNoPaneDialsThePreviousHostsIdsAtANewHost` asserts the opposite for a different host key.

### 6. What the gates can and cannot see

`scripts/check-launch-restore.sh` reaches the shipping launch path and its phase C still pins the
launch arm on hardware. It cannot reach a host switch — one hostd, one port — and neither can any
other gate, so the host-switch arm is pinned headlessly and this entry says so rather than claiming
coverage that does not exist. The honest residual: the second host's 2N shells are measured on the
in-process rig, not on two real hostds.

## The establish fan-out runs before the subscription, and the document is its second chance (2026-07-29)

An adversarial review of the three commits above found a regression the ten hardware gates are blind
to. `handleConnectionEstablished()` had been reordered to open the workspace subscription first, so
that the provenance stamp would be armed before any pane could dial. But `startWorkspaceChannel()`
stops the old subscription, `stop()` resets the mirror, and `WorkspaceStore.tree` is a pure
PROJECTION of that mirror — so `redialDisconnectedPanes()` iterated an EMPTY pane set on every
reconnect. A pane that gave up to `.failed`/`.unreachable` during an outage was never revived: a dead
terminal behind a green "Connected" pill, until the user hits per-pane Reconnect once per pane.

### 1. The order is forced by the projection, not chosen

The fan-out has to read the pane set before anything resets it, so it goes first. What keeps that
safe at a NEW host is not the order — it is `panesMayDial`, which is already holding by then because
`commitConnectionTarget(_:)` stamps the new host before the connection reports up, and the provenance
rule refuses ids the attached host has not named.

### 2. `.closed` is not "nothing is coming"

`resolvedPaneDialGate()` read `.closed` as a host that will never publish, and answered `true`. That
is the state the app is ACTUALLY in when the next target is committed, since the shared connection is
torn down before the new endpoint is stamped — so the arm handed a host switch exactly the dial it
exists to prevent. `.refused` keeps that answer, because a host that declines `channelClass 1` really
will never publish one; `.closed` falls through to provenance, bounded by `paneDialHoldBackstop`.

### 3. The flap that beats the snapshot needs an edge nothing else provides

An establish arriving while the mirror is already empty — the previous establish re-opened the
subscription and the link died again before the snapshot answered — has no pane set to iterate at any
point in the method, and the gate never moves, because the host that confirmed those ids is still the
host being dialled. `armPaneRedialOnDocument()` books the fan-out a second run; the first document
frame the ATTACHED host folds spends it, which is the one instant at which the panes are back on
screen and their provenance is settled.

### 4. What made the previous test unfalsifiable, and the rule that follows

`testNoPaneDialsThePreviousHostsIdsAtANewHost` claimed "RED at six channels for three panes" while
its dial-count assertion could not fail: the same reset emptied the tree before any redial could see
it, so the count stayed at 3 with the provenance rule fully disabled. It now asserts a precondition
that host A's layout is still on screen when the fan-out runs. Verified by neutering
`resolvedPaneDialGate()` to `return true` and confirming the count line fires at 6 vs 3 — the number
hardware produced. **A test over a projection must pin that the projection is populated, or it is
asserting about an empty tree and the code it claims to cover can be deleted outright.**

## A cold launch keeps the layout it restored, because the reset has nothing to forget (2026-07-29)

The window the user restored from disk left the screen the instant the connection came up.
`handleConnectionEstablished()` re-opens the subscription, `WorkspaceChannelClient.stop()` resets the
mirror on the way, and `WorkspaceStore.tree` is a pure projection of that mirror — so every establish
blanked the layout and the window stayed blank until a snapshot answered.

The reset is right when there is host truth to forget: keeping `entries` across a reconnect would let
a diff apply against a document the host may have replaced. A COLD launch has none. Everything in the
mirror is the store's own seed, carried under `WorkspaceStore.seedEpoch`, and throwing it away buys
nothing — the next subscribe declares `stateNum 0` and gets a full snapshot either way. So the reset
is now conditional on `WorkspaceMirrorBox.holdsHostDocument`, which is the same test
`noteFoldedDocumentProvenance()` already used to decide whether a host had spoken. `framesApplied`
cannot answer it: the seed is folded like any other frame.

What this closes is the blank window with no error on it — a host that accepts the connection and
then never publishes (a class it does not know, a wedged daemon, a link that dies mid-subscribe) used
to leave the user with nothing to look at. That is the same failure the deleted `SLOPDESK_WORKSPACE_DOC`
produced in its OFF position, arrived at by a different road.

Showing is not dialling. The restored ids are still unconfirmed, so `panesMayDial` keeps them from
opening a PTY until the attached host names them — the division of labour the hold was built for, and
the reason a possibly-stale layout on screen is inert rather than dangerous.

**Deliberately not changed.** A WARM reconnect — one where the host has already published — still
resets, so the window is empty for one round trip and, if that link also dies, until a subscribe
succeeds. Suppressing that would mean holding one host's entries across a reconnect, which is exactly
the hazard the reset exists for. `armPaneRedialOnDocument()` already covers the redial half of that
window.

**Latent, recorded rather than fixed.** `attachWorkspaceChannel(_:)` stops the outgoing channel — and
so may reset the box — after `attachLoopbackWorkspaceDocument()` has published its adopt. Replacing a
live host channel with a loopback would therefore erase the document the loopback is authoritative
over. Unreachable today: the shell installs one channel at startup and never replaces it.

## The workspace handshake is bounded, because silence is not a verdict (2026-07-29)

`WorkspaceChannelClient.run()` awaited the host's `channelOpenAck` with no clock on it. The pane path
bounds the identical wait — `MuxClientTransport.race` against one `handshakeTimeout`, and its comment
names the case: a dead host mid-open. The document path did not, and it is the path whose silence
costs the most.

A host that registers the channel and then never acks leaves the loop suspended for the life of the
process. `state` never leaves `.opening`, and nothing anywhere reaches that: `workspaceChannelState`
has four readers and not one of them is a watchdog. No reopen is attempted, no subscribe goes out, no
snapshot arrives. The window keeps drawing per-pane facts off the control-push sinks while its LAYOUT
sits frozen at the last fold, with nothing on screen to say why — the same blank-window class as the
deleted `SLOPDESK_WORKSPACE_DOC` and the establish reset, reached by a third road.

`paneDialHoldBackstop` still frees the panes to dial, so the state is survivable. That is exactly what
made it invisible: the panes work, the layout is simply never the host's again.

**`.closed`, never `.refused`.** A refusal is a host stating it does not serve `channelClass 1`, and
it stops this client for good — `resolvedPaneDialGate` reads it as "no document is ever coming" and
releases the hold on that basis. Silence states nothing about the host, so it has to stay retryable;
the connection layer's next establish re-opens.

**The test double had to learn cancellation.** The race cancels the loser, and `withTaskGroup` awaits
every child at scope exit. A poll loop that swallows cancellation with `try?` spins instead of
returning, which keeps the group open and turns the bound back into the hang it was added to remove.
The production awaiter (`MuxNWConnection.awaitOpenAck`) already resumes a cancelled waiter; the rig's
`VerdictBox` now does too.

**How it was found.** A mutation that made the host drop the workspace route silently did not turn
`WorkspaceChannelLoopbackTests` red — it hung xctest for 77 minutes. The unbounded wait in the rig's
`awaitOpenAck` is what stranded it, in a file whose own comment states the rule every wait in it must
be bounded.

## Read-only attach is removed; class 2 stays reserved (2026-07-29)

`channelClass == 2` opened a pane somebody else already held as a **read-only** member: the host
joined it to the live session, dropped its `input` frames (while still crediting them), skipped the
echo probe and `foldUserInput`, and kept it out of the PTY size fold for good. `slopdesk-client
--observe` was the one caller. It is gone — route, CLI flag, `Subscriber.channelClass`, the
`readOnly` fork in `startInputRelay`, and `ResizeContribution.observer` with it.

**Why.** Read-only attach exists in tmux (`attach -r`) and `screen` (multiuser ACLs) to serve pairing
and demos — one person driving while others watch. This product is one human on their own machines,
where every attachment is a hand that should be able to type. Nobody asked for a spectator seat.

The cost was not the route. It was that "read-only" is a property of a SUBSCRIBER, so it leaked into
every per-member path: a branch in the input relay that three other writers had to be reasoned about
against, and a passivity flag the size fold could never let expire — an exception carried by code
that is otherwise about one thing, sizing a grid for the people who are here.

**The enum case goes; the byte does not.** `MuxChannelClass` now names 0 and 1 only, and 2 falls into
the existing unserved-class guard: `accepted: false`, decided BEFORE the exclusivity critical section,
so a stale peer that still sends `--observe` is refused rather than handed a login shell it never
asked for. Nothing on the wire changed shape — the class field was already golden-pinned at 0 and 255
— and 2 is not reusable, because one byte must never name two things.

**What kept its coverage.** The observer suites pinned two behaviours that were not about observing at
all: that a JOINED member's input reaches the PTY, and that a joined member's Esc folds through
`foldUserInput` to drop a blocked agent's hand. The primary's relay is built at `init`, so both would
stay green while a joiner's relay went nowhere. They live on in
`MuxChannelSessionJoinedInputTests`. The size-fold cases the observer tests covered were the
size-passive ones, already pinned by `MuxChannelSessionResizeFoldTests`.

## Two clients CAN watch one window; the refusal that was never written stays unwritten (2026-07-29)

**Decision.** A second client's video pane ships as a real stream, not as a placeholder. The
`docs/45` §10 risk row that reserved the right to render it **unavailable** is retired, and no
refusal is added on either side.

**Why the row existed.** The workspace document advertises `pane/videoTarget` to every attached
client, so a second client sees the desktop pane and will dial it. Whether the host could serve that
— two `SCStream`s and two `VTCompressionSession`s bound to ONE capture target — was never
established, and hang-safety forbids constructing any of those four objects in a unit test. So the
document made a promise the test suite structurally cannot check.

**What settled it: measurement, not a guard.** `scripts/check-video.sh --second-client` stands up the
real videohostd, a real `slopdesk-hostd`, and two client instances. Client B is given the TERMINAL
autoconnect and nothing else — no `SLOPDESK_VIDEO_AUTOCONNECT_*` — so it has to learn the pane from
the host's document, resolve the ports off its `ConnectionTarget` defaults, and dial a window nobody
named to it. It decoded and presented. That is the whole claim, and it is true.

**The assertion that matters is the PAIR.** A host that could hold only one session per target might
hand the newcomer the stream and leave the incumbent on a frozen last frame — and every other check
in the gate would still pass. So client A's decode counter is re-read after B is up and must have
GROWN (16 → 34), and each client's media lane is asserted per-PID rather than by counting sockets on
the media port, where the host's own bound socket also lives.

**One shot per instance, raised by PID.** Two instances are two processes named SlopDesk, so
`first process whose name is "SlopDesk"` photographs whichever the window server answers with — one
client, twice, presented as two. Each instance is raised by its unix id and shot separately. B's
frame is visibly NEWER than A's, which is what makes it a live second stream rather than a copy.

**The refusal was documented but never coded.** The retired row described "the refusal in the
client's video-pane materializer" — there is no such code and there never was. A mitigation that
exists only in prose is worse than an open risk: it reads as handled. The row now records what was
measured, on which date, by which command.

## ⌃⇥ is a held gesture the dispatcher owns, not a chord-table row (2026-07-29)

**Decision.** Tab switching gains a second gesture: hold ⌃ and tap ⇥ to walk a MOST-RECENTLY-USED
ring, release ⌃ to commit — kero's `TabSwitcherView` shape. It lives in `WorkspaceKeyDispatcher`, not
in `WorkspaceBindingRegistry`'s chord table. The positional ⌘⇧] / ⌘⇧[ cycle and ⌘1–9 are unchanged.

**Why not a table row.** A row maps ONE chord to ONE action. ⌃⇥ means three different things
depending on state — open, step, commit — and the commit is not a keystroke at all but a modifier
key-up. There is no row shape that says that. Worse, adding it would put a ⌃-only chord into a table
whose invariant (`testEveryChordIsCommandOrOptionPrefixed`) requires ⌘ or ⌥ on every chord. That
invariant is not decoration: it is the thing that keeps the app from swallowing a ⌃-letter the TUI
needs. Muxy has no such rule and its ⌃[ binding eats ESC.

**Why ⌃⇥ is free to take.** xterm's `modifyOtherKeys` explicitly EXCLUDES Tab, so in a legacy
terminal ⌃⇥ is byte-identical to bare ⇥ — nothing can distinguish them, so nothing can be bound to
it. macOS reserves ⌘⇥ at the WindowServer level but leaves ⌃⇥ to the app. Under the Kitty keyboard
protocol it does become distinguishable (`CSI 9 ; 5 u`), which is why the escape hatch below exists.

**What it must not cost.** Bare ⇥ is shell completion and ⇧⇥ is how Claude Code cycles permission
modes. Neither carries ⌃, and the dispatcher claims Tab only when ⌃ is held or the switcher is
already up. `DispatcherTabSwitcherTests` pins both passthroughs first, before anything else.

**The highlight is LOCAL; only the commit is an intent.** Walking the ring stages nothing. The host
owns tab focus (`docs/45`), so staging a `.focusTab` per step would broadcast every intermediate tab
of a cycle to every other attached client and repaint their screens. One commit, one intent.

**The ring is FROZEN at open.** Candidates are snapshot from `WorkspaceTopology.focusMRU` when the
switcher opens. Committing re-fronts the ring, so a live ring would reshuffle under a still-held ⌃
and the highlight would chase itself. The order is: local active tab, then the host ring by recency,
then anything never visited, deduped and pruned to live tabs.

**Escape hatch.** `unbind: ctrl+tab` frees the gesture back to the PTY, for the Neovim user who has
bound `<C-Tab>` and runs with CSI-u on. It gates OPENING only — an open switcher owns ⇥ regardless,
or the unbind would strand an overlay with no way to step it — and reclaims each chord individually:
unbinding ⌃⇥ says nothing about ⌃⇧⇥.

**A focus change elsewhere abandons the walk.** The switcher can also be opened from the palette
(the chord-less `tab.switcher` row), and that one has no held modifier whose release would end it.
Both `stageFocus` overloads cancel it first — that pair is the choke point every local navigation
passes through — so clicking into the workspace cannot leave a card floating over a view the user
has already left.

**Not rebindable as a gesture.** Settings can rebind the chord-less `tab.switcher` row (which opens
the unarmed switcher), but the held ⌃⇥ gesture itself is fixed. Accepted: expressing "hold this
modifier, tap that key, commit on release" in the recorder UI is a larger change than the gesture is
worth, and `unbind:` already covers the user who needs the chord back.

## The notification is a pane speaking from off-screen: the rail's mark, and a door (2026-07-30)

**Decision.** The in-app notification stack is redesigned. It keeps the CARD register (it is not migrated
to the `NoticeChip` one-liner), but the card is rebuilt around one reading: every push site is gated on
the source pane NOT being focused, so a toast always names a place the user is not looking at. That makes
it three things — WHO spoke, WHAT happened, and the WAY BACK.

**There is NO LEADING GLYPH — the event class is an EYEBROW.** A caps micro-label in the instrument voice,
letterspaced with `instrumentTracking` and inked with the flavour hue, then `·`, then the subject, all on
one line. This is MERIDIAN L2 taken literally ("typography is the only ornament") and it is the DS's
existing engraving treatment (`SlateRow`, `SlatePopover`, `InstrumentChip`, `NavigatorColumn`), not a new
device. With no glyph column, every line starts on ONE left rail.

**Two leading elements were built and cut to get here.** First the SF Symbol quartet (`bell` /
`checkmark.circle` / `exclamationmark.triangle` / `asterisk`) — four glyphs from four families that never
shared a stroke weight, and the very pictograms rounds 19–21 pulled off the rail. Then the rail's own
`StatusDotView` ring/dot, which the user rejected with the decisive observation: **the ring/dot pair is
right in a 10pt sidebar column and wrong in a notification**, where it is a tiny abstract speck and the eye
expects something concrete. Borrowing the rail's vocabulary looked like consistency and was actually a
category error — the rail is a dense scannable column, a notification is a single interruption.

**Liquid Glass was considered and dropped.** The package floor is macOS 26 / iOS 26 (`Package.swift`
`.v26`), so `glassEffect` is available with no `#available` gate and no fallback path — it was a real
option, and a floating transient card is Apple's own canonical use for it. Rejected on system coherence:
`SlopDeskClientUI` contains **zero** materials anywhere (MERIDIAN L5 — depth by light, not lines; v5 already
deleted `GlassPanel`), so one glass card would be the single alien surface in the app.

**A monogram identity plate was probed and rejected.** `SlateMonogram` (MERIDIAN C2) was the closest
DS-native equivalent of a real notification's app-icon tile. It fails on the hue budget: the plate's
per-identity colour is designed to be a PERSISTENT identifier for a host, and in a transient notification it
puts a SECOND colour system on the card, fighting the status hue — four notifications become four unrelated
hues, exactly the chromatic spread the v5 bar calls slop. **Colour lives in exactly one place: the eyebrow.**
The surface is never tinted by flavour and there is no coloured edge rail.

**Flavour alone could not pick the eyebrow**, and that is why `Toast` grew a second bit, `source`
(`.agent` / `.command`). `.success` says `DONE` for an agent and `FINISHED` for a command; a resolver keyed
on flavour would have announced a finished `make` as an agent turn. This is the same fusion
`TabBadgeResolver` had (round 21) — pinned by `testEyebrowSplitsAgentFromCommand`. A factory may override
with `Toast.eyebrow` when it knows a truer word than the derivation can reach: the reconnect verdict is
`REATTACHED` vs `RECONNECTED`, a distinction no flavour encodes.

**`.attention` is AMBER, not the theme accent — and the old pin was hiding the bug.** The user asked why
needs-input was cyan rather than yellow, and the codebase already had the answer: ``StatusDot`` fixes the
rail's mapping as "green = an unread finish, **amber = a question waiting**, red = failed", so an agent
waiting on a human has to be amber here too or the app contradicts itself about what amber means. Worse, the
accent was not even *distinguishable*: every Monokai seed sets `info == accent`, so `.attention` (needs
input, the highest-signal event) and `.default` (a routine OSC notice) rendered in the SAME cyan — the one
pair that most needs to differ. The previous test explicitly declined to assert those two apart, documenting
the collision as acceptable instead of failing on it. `.attention` now takes the status quartet's unused
amber rung, which also leaves the accent free for its single job (active state). Pinned by
`testEveryFlavorInkIsDistinct`, which asserts all four flavours PAIRWISE distinct — the real invariant, since
a flavour that cannot be told from another conveys nothing.

**Card corner → `Slate.Metric.radiusPanel` (12), a new rung.** `radiusCard` (8) is tuned for content INSET
into a surface; at the notification's 320 × ~46pt it reads boxy, and 16 slides toward `radiusPill`. Picked by
rendering 8 / 10 / 12 / 16 at true size side by side.

**The card is a door.** `Toast.paneKey` carries the pane, and the mount site routes a tap through
`jumpToPaneTree` — the seam `ConnectionAlertChip` already used, so a landing that crosses a tab fires the
"JUMPED · session ▸ tab" breadcrumb. Before this the toast was strictly LESS capable than the chip beside
it: it named somewhere else and could not take you there. The two window-level notices with nowhere to go
(the failed host-path action, the dropped-folder cwd advisory) pass no `paneKey` and stay inert.

**The dwell pauses on hover, and NOTHING draws it.** A pointer resting on a card freezes its clock, so a
notification can no longer be yanked away mid-read — the 4s timer used to do exactly that. The countdown is
therefore SAMPLED (a 10 Hz tick that simply does not advance while hovered) rather than a single
`Task.sleep`, which could not be paused.

**A visible dwell track was built and CUT — the user judged it AI slop.** The first cut of this round put a
capsule hairline of the flavour hue along the card's bottom edge, depleting over `autoDismiss` and freezing
on hover, argued for as a READOUT in the same family as the long-command elapsed chip and the OSC 9;4
percent ring that the v5 restraint pass kept. The ruling: it reads as decoration on the resting card, and
the v5 bar ("permanent per-item ornament reads as AI slop") applies. `Slate.Anim.drain` and
`Slate.Metric.trackThickness` were added for it and are deleted with it. **The fix for "it vanished while I
was reading" is that it STOPS, not that it announces how long it has left.** Do not propose a progress
bar / ring / countdown on a notification again.

**The spine.** Only the newest two cards carry a detail line; older ones collapse to the eyebrow + subject
row alone, so a four-deep burst costs about a third of the corner instead of blanketing the prompt line.
Hovering a collapsed row expands just it, and rows are promoted as the cards below them expire — so no
information is stranded on iOS, which has no hover.

**The ✕ is hover-only** (unconditional on a sticky card, whose only exit it is). Four permanent ✕ marching
down the corner was chrome for something that leaves by itself. Hidden it is also not a hit target, so a
stray click cannot kill a card the user never saw a ✕ on.

**Uniform width, NOT content-hugging — reversed after rendering it.** Cards that hugged their own content
were built first and photographed as a ragged staircase: right-aligned in the corner with every left edge
landing somewhere different, and the width tracking TITLE LENGTH rather than importance. `toastWidth` is
one column edge at 320 (down from 340, affordable because the ✕ no longer holds a permanent slot).

**Surface + voice.** The fill moves from `Surface.face` — the EXACT tone of the terminal behind it, leaving
a dark-on-dark shadow as the only separation — to `Surface.raised`, the rung every other floating chip
already used. Typography moves to the INSTRUMENT voice (MERIDIAN L2): a body like `exit 1 · 42s` is a
technical readout, and setting it in proportional system text was the single thing that made the stack read
as a web toast pasted into a terminal app. The three factory bodies are re-cut as `·`-joined readout
fragments rather than sentences.

**Bonus fix: a same-id re-push now RESTARTS the dwell.** The card's timer was keyed on `Toast.id`, which a
replace does not change, so the replacement inherited the replaced toast's nearly-elapsed dwell and could
vanish almost at once. `Toast.epoch`, stamped by `pushToast`, is the `ChipNotice` remedy applied here —
pinned by `testSameIDRepushTakesAFreshEpoch`.

→ `Overlays/Toast.swift`, `Overlays/ToastStackView.swift`, `Overlays/OverlayCoordinator.swift`,
`Overlays/OverlayHostView.swift`, `DesignSystem/SlateDesign.swift`, `SlopDeskClientApp.swift`,
`Pane/PaneDropReceiver.swift`, `Pane/TerminalLeafView.swift`; pinned by `ToastStackViewTests`
(mark split, spine rule, epoch, render smoke over the PANE tone so card-vs-pane separation is
actually visible), `ToastSessionResumeTests`, `ToastSecretRedactionTests`. No wire change (golden
byte-identical).

**The states are PHOTOGRAPHABLE, and that is how this round was decided.** `ToastStateGalleryTests` dumps
the whole state space — every (source, flavour) eyebrow, rest vs hover, both stack tiers, sticky, the
content edges, the real 4-deep stack, and a light-theme pass — as PNGs:

    SLOPDESK_TOAST_GALLERY_DIR=/tmp/toast swift test --filter ToastStateGalleryTests

`ToastCardView` is internal (not file-private) with a seedable `hovering`, purely so the hovered states can
be captured at all: `ImageRenderer` never delivers a hover. Two decisions in this round were REVERSED by
looking at the output rather than at the code (content-hugging width, the dwell track), and the leading
mark was rejected the same way — which is the argument for keeping the harness.

## The working row's title shimmer is removed; the mark column speaks alone (2026-07-30)

The generating agent's title no longer sweeps a highlight band across its own glyphs. Round 23 shipped
the shimmer as a SECOND voice on a fact the trailing spinner already states, on the argument that a rail
running several agents at once wants the signal where the eye already is. Looked at on hardware, the
second voice is the problem: the rail is a column the eye SCANS, and a row whose text is in motion
takes the scan hostage — the redundancy that justified the effect is exactly what makes it noise.

- ✅ **One row-level signal, in the mark column.** `ProgressView`/`NSProgressIndicator` on the raw
  `.working` row (round 23) is the whole statement. The title is back to still ink at every state,
  which restores the round 19 rule the shimmer had carved an exception into: a settled rail does not
  move, and the ONLY thing that moves is the mark for work in flight.
- ⚠️ **Text motion is not available as a "free" second channel.** The shimmer cost no hue and moved no
  layout, which is what made it look cheap on paper; the cost it actually charges is attention, and it
  charges it on the surface least able to pay. Do not re-propose a travelling highlight, a pulsing
  title, or a stepped title weight for liveness — the mark column is where liveness lives.
- ✅ Everything else round 23 decided stands: otty's 14×14 badge box, the SVG path reader, the raw
  `.working` gate (never `isBusy`), and the two speakers (agent check / command disc).

→ deletes `DesignSystem/Shimmer.swift`, `ShimmerTests`, `SlateTabRow.shimmerPhase` (the pinned-phase
snapshot seam) and `SlateSnapshotRender.testRenderWorkingRowShimmer` with its GIF writer — the harness
existed for the one mark whose evidence had to be animated, and there is no longer such a mark.

## Settings speaks the SYSTEM, and every remaining control does something (2026-07-30)

Three complaints about the Settings surface, one root each. It was painted in the active Monokai Pro
filter, so a preferences window sat dark on a light Mac with theme-tinted labels beside system-blue
switches; it turned choices into picture-card grids even where the picture was a stand-in SF Symbol; and a
long tail of its toggles wrote a value nothing ever read.

- ✅ **Settings is OS chrome, not product surface.** Colour + type now come from `SettingsInk` /
  `SettingsType` — AppKit/UIKit semantic colours and Dynamic-Type text styles — instead of `Slate.*`. The
  scene no longer sets `.preferredColorScheme`, and `SettingsWindowAppearancePinner` is deleted: the window
  follows the OS appearance like System Settings does. **The one exception is the theme gallery**, whose
  swatches must draw from the `SlateTheme` they are PREVIEWING — painted in system colours they would be
  seven identical cards.
- ✅ **A card must be earned by its picture.** Cards stay where the illustration IS the difference (cursor
  caret, tab position, ⌥ key row, window geometry, theme swatch). The glyph-card groups — Right-Click
  Action, On Launch, Close Confirmation — are `SettingsOptionMenuRow`s: same pinned `SettingsOption` lists,
  same exhaustiveness test, one row instead of a grid. `SettingsSymbolArt` and `SettingsOption.symbol` are
  deleted so the shape cannot come back by accident.
- ✅ **One card size, everywhere.** The grid was `.adaptive(minimum:)`, which STRETCHES columns to fill —
  a 2-option group rendered two enormous cards while the theme gallery rendered seven small ones. Columns
  are now fixed at `settingsCardWidth` (96 → 116) and wrap; `settingsSwatchArt` is gone, so the theme
  swatch shares the one `settingsCardArt` band.
- ✅ **A setting that only writes to disk is deleted, not disabled.** Same criterion as the 2026-07-29 flag
  purge: if OFF is not a valid mode but a broken product, it is not a flag — and if neither position does
  anything, it is not a setting. Removed (control + `SettingsKey` + `Defaults.Key` + accessor + catalog
  entry + reset lists): **Scroll to Bottom on Output** and **Show command dividers** (ZERO read sites
  anywhere), **Backspace Deletes Selection**, **Scroll Past First / Last Line**, **Smooth Scroll**, **Cursor
  Animation**, **Render SGR underlines / blink**, the `srgb-over` / `linear` / `perceptual` **blending**
  modes and **Title Report** (all wired-but-inert: the code path exists and provably cannot change what you
  see), and the client-side **IPC — Allow Send Keys / Allow Sensitive Sessions** + **Auto Progress-Bar
  Commands** keys (see below).
- ⚠️ **The IPC / auto-progress keys were worse than inert — they were a lie in the doc comment.** Their
  description claimed a `SLOPDESK_IPC_ALLOW_*` env bridge re-drove the host on its next launch. No such
  bridge exists: `applyVideoAndAgent()` folds only `video ∪ agent ∪ rawOverrides` into the overlay and the
  sidecar, so the toggle never left the client. The honest editor for a host-read env key is **Advanced →
  Raw overrides**, which DOES reach the sidecar — the host resolvers are unchanged.
- ⚠️⚠️ **`grep Sources Apps` DOES NOT COVER THE CLIENT.** The audit that drove this round first reported
  Mouse Over to Focus, Undo at Prompt and Backspace-Deletes-Selection as unreferenced, because the live
  reader of all three is `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — the
  `TerminalSurface` seam that ONLY the Xcode app target compiles, which is why `swift build` stayed green
  after deleting them. **Mouse Over to Focus and Undo at Prompt are real and were restored.** Any
  "is this setting reachable?" sweep must include `ThirdParty/ghostty/integration/` and `Apps/`, and must
  end at `xcodebuild -scheme ClientApp-macOS`, not at `swift build`.
- ✅ **Backspace-Deletes-Selection was wired and STILL dead.** `BackspaceSelectionPolicy` was called, but
  its one interesting leg passed `selectionEndsAtCursor: false` unconditionally (no geometry API), so
  `leadingDeleteCount` always returned 0 and every branch fell through to the same encoder path — ON and
  OFF identical by construction, as its own comment admitted. A call site is not evidence of an effect.
- ⚠️ **Deleting a setting deletes its pure engine too.** `BackspaceSelectionPolicy` and `ScrollPastPolicy`
  each had a full unit-test file and no reachable effect — a green suite over engines nothing could act on,
  which is exactly how an inert toggle survives review. Gone with their tests and the `ScrollPastLast` /
  `ScrollPastFirst` enums. (`FocusFollowsMousePolicy` / `PromptEditPolicy` stay: theirs DO act.)
- ⚠️ **`CutSelectionPolicy` is uncalled** and was LEFT in place: it is not behind a Settings toggle, so it
  is out of this round's scope. Wire it to ⌘X or delete it, but do not let it become the next example.

→ adds `Settings/SettingsInk.swift`; touches every file under `Sources/SlopDeskClientUI/Settings/`,
`SettingsKey.swift`, `AllSettingsCatalog.swift`, `PreferencesStore.swift`, `TerminalControls.swift`,
`TerminalPreferences.swift`, `TerminalFontSettings.swift`, `SlateDesign.swift`, `HostEnvironment.swift`,
`AutoProgressMatcher.swift` and `GhosttyTerminalView.swift`. No wire change (golden
byte-identical) — every removed key was a fire-time `Defaults` flag or a client-only render pref.

## ⌘W is a PANE gesture: an emptied tab just goes, it is not a tab close to confirm (2026-07-30)

⌘W on a tab holding ONE pane popped *"Close “Terminal”? / This window has multiple tabs."* Two independent
faults stacked, both dating to the E7 carry-over #8 fix, which corrected WHICH policy a pane close reads but
not what that policy is fed.

- ✅ **A pane close reads the busy-shell guard ALONE.** E7 made a pane close inherit the Tab policy whenever
  it cascaded its tab away (`tabRemovedByClosing ≠ nil`), escalating to the Window policy on the session's
  last tab. **Ruling: it inherits neither.** A tab is a container for panes; there is no pane-less tab, so a
  tab vanishing with its last pane is a CONSEQUENCE of the pane close, not a second close the user asked
  about. `closeConfirmationNeeded(scope: .pane)` is now `shouldConfirm(.process, isBusy:)` — ⌘W asks only
  mid-command. The Tab and Window policies belong to their own affordances (Close Tab, ⌘⇧W Close Window).
  `effectivePanePolicy(for:)` and `tabRemovedByClosing(_:)` are deleted with it, and
  `pendingCloseReasonPolicy` returns `.process` for any parked PANE close.
- ✅ **`multiple_tabs` counts the tabs the close DESTROYS, not the tabs the window happens to hold.** All
  three scopes were fed `tree.activeSession?.tabs.count`, so "ask when this would lose more than one tab"
  fired on a unit that loses exactly one — and then narrated it in window-scope copy. `.tab` now feeds `1`,
  `.pane` is `.process` (count irrelevant), and only `.window` feeds the session's `tabs.count`.
- ✅ **That makes `multiple_tabs` window-only, so the tab row stops offering it.** Same criterion as the
  2026-07-30 Settings purge: a control position that provably cannot change anything is not a choice.
  `SettingsOptionCatalog.closeConfirmationTab` is the window list's first two entries (a prefix, so the two
  rows can never word the same policy differently); `AllSettingsListView` composes its tab picker into the
  window one. A persisted `multiple_tabs` on `shell.closeConfirm.tab` stays decodable and is simply inert.
- ⚠️ **The old test pinned the behaviour being removed.** `testAlwaysTabPolicyParksAnIdlePaneClose` and
  `testCascadingPaneCloseUsesTabPolicy` both asserted a pane close inheriting the Tab policy. Rewritten to
  assert the complement — and to assert the SAME `.always` policy still parks an explicit Close Tab, which is
  the pin that keeps this from collapsing into "nothing ever confirms".

→ touches `WorkspaceStore.swift`, `WorkspaceStore+CloseConfirmation.swift`, `SettingsOptionCatalog.swift`,
`SettingsView.swift`, `AllSettingsListView.swift`, `AllSettingsCatalog.swift`,
`CloseConfirmationPolicyTests.swift`. No wire change (golden byte-identical) — both keys are fire-time
`Defaults` and `CloseConfirmationPolicy` keeps all three cases.

## The ⌃⇥ switcher names the PANE, not the place — and wears the system's glass (2026-07-31)

The switcher printed one line per tab through the folder-name rung, so a session with three panes open in
one repo read `slopdesk` / `slopdesk` / `slopdesk`. The ring was ordered by RECENCY and named by PLACE: the
only question the surface exists to answer — which of these am I flipping to — was the one it could not.
The user also judged the hand-drawn Slate card un-native.

- ✅ **The card is a grouped LIST: the project heads a section, a row is ONE line.** The first cut gave each
  row an icon, two lines and a full-bleed selection bar; the user's verdict was *"xấu thế, nhìn nó không
  thanh lịch tí nào"*. Ruling (chosen from three previews): project as a section header said ONCE, rows
  reduced to identity + a quiet note + the ⌘-number, highlight an inset capsule. The icon goes (every row is
  a terminal — the glyph was noise) and so does the second line (it restated the header on every row).
  Identity resolves through `RailRowsBuilder.liveRowTitle(...)` — the SAME chain the sidebar row and the
  window title read (rename → agent task intent → running command → last command → folder) — so a pane is
  named identically wherever it is named. The note carries the sub-path below the project and `N panes` when
  the tab is SPLIT (a tab in `slopdesk` holding three panes is not the destination holding one), and is
  absent for the common at-root single-pane row, which is what makes the list read quiet.
- ✅ **A header is a RUN BOUNDARY, not a re-sort.** The display order is the frozen ring's (recency) because
  that is the order ⇥ steps in; grouping the rows by project would make the highlight jump around the card.
  So a header is emitted wherever consecutive rows change project, and one project can head more than one
  run. A projectless row (video pane, cwd not landed) heads nothing and continues the run above it rather
  than scattering an "Other" bucket. `TabSwitcherItem.id` is the POSITION, not the name — names repeat.
- ✅ **A title that only restates its header yields to its program.** The identity chain's last rung is the
  folder name, which under a section header is the header printed twice; an idle root shell therefore reads
  `zsh` (the sidebar's metadata slot). Only when no program is known does it restate the folder — a blank
  line says less than a redundant one.
- ✅ **`projectKey` IS threaded into the structural rung, on purpose.** At the project root that rung yields
  the PROGRAM rather than the folder name, and an idle shell's empty result then falls through to the
  running / last command / folder. That fall-through is the whole disambiguation: without the key every row
  short-circuits at the folder name, which is the bug.
- ✅ **The card is native chrome, not canvas.** `glassEffect(.regular)`, system text styles, semantic
  `.primary`/`.secondary` ink, the SF Symbol `PaneChooserRegistry` already names each kind by, and the
  SYSTEM accent for the highlight — `.tint(nil)`, because the window tints its whole subtree with the THEME
  accent and a native surface wearing Monokai green for its selection is exactly the un-native reading. Slate
  supplies GEOMETRY only (the shared spacing/radius ladder), never ink. Per the native-chrome research's
  pitfall list the custom glass self-gates `accessibilityReduceTransparency` → `.regularMaterial`.
- ⚠️ **Glass over the live terminal canvas WORKS.** The 2026-07-03 research said never layer glass over a
  live `CAMetalLayer`; HW-photographed on mac-studio over a running `top` under libghostty, the backdrop
  samples correctly in both a light and a dark theme. The rule stands for a pane's OWN surface (the
  one-surface rule); a transient overlay ABOVE it is fine.

→ touches `TabSwitcherOverlay.swift`, new `TabSwitcherRows.swift` (+ `TabSwitcherRowsTests.swift`). No wire
change (golden byte-identical), no model change — `TabSwitcher` (the frozen ring) is untouched, and the
dispatcher still owns open/step/commit/cancel.

### Round 3 — the accent capsule loses, the shortcut becomes a KEY (2026-07-31)

The grouped list was still rejected (*"vẫn xấu"*), with one hard defect attached: *"bên trái title dài quá
thì bên phải sẽ bị cắt"*. This time the three candidates were BUILT and photographed side by side at true
size over a live workspace, and the ruling was made on pixels — ASCII previews had already produced one
approved-then-rejected round.

- ✅ **The ⌘-number is a keycap with `fixedSize`, and that is a CORRECTNESS fix, not a style one.** The title
  carried `layoutPriority(1)`, so in a narrow `HStack` it took its ideal width first and the shortcut was
  truncated down to a bare `⌘`. A shortcut with its number cut off is not a shortcut. The keycap is laid out
  first now; the title takes what is left and truncates; the note (`layoutPriority(-1)`) yields before both.
  The key is also ABSENT past ⌘9, where the app binds no chord — an unpressable key drawn on a row is a lie.
- ✅ **No hue anywhere: the highlight is a lifted plate + a heavier title.** The system-accent capsule read as
  a foreign object on a quiet card. This restates the house rule the git line and the footer already follow
  (*"có vấn đề" = brighter + bolder, never a colour*) — the switcher is a readout like the rest.
- ✅ **Roomier: `heightRowTall` (44) joins the ladder, the card widens to 460.** A 32pt list beat is for
  SCANNING; this surface is read at a glance for the length of a held modifier, and a real pane title (a
  running command, an agent's stated intent) has to finish on the line.
- ✅ **Glass needs a RIM and a SHADOW to read as glass.** Over a dark terminal `glassEffect` alone leaves a
  grey slab. The surface adds the two things a physical pane of glass has: a specular edge (theme-directed —
  light on dark, darkened on light) and a cast shadow. `.tint(nil)` is no longer needed, since nothing on
  the card is tinted.
- ✅ **One project ⇒ NO header.** A caption over a run that has nothing to be distinguished from is a label
  on a box holding one thing; the header survives only where it does work — a list spanning several
  projects. ⚠️ Trade-off taken knowingly: a single-project card no longer names the place. The
  title-yields-to-its-header rule stays UNCONDITIONAL even when no header is drawn, because that rule exists
  to stop every row collapsing to the folder name — which is the original bug, not a header artefact.

## A Claude Code hook must never park on the host (2026-07-31)

Editing through Claude Code kept freezing on `Update`, and `UserPromptSubmit` intermittently reported a 30s
timeout. Both are the same defect, and it is ours: the installed `slopdesk-agent` hook POSTs each event over
`nc -U` to the host's `AgentHookListener`, and Claude Code runs that hook SYNCHRONOUSLY — on `PreToolUse` /
`PostToolUse`, i.e. around every single edit — waiting up to 30s.

`UnixSocketAcceptor.acceptLoop` accepted ONE connection at a time and ran `onRecord` inline on the accept
thread, so a slow sink left every other pane's connection unaccepted and `nc` sat there until Claude Code's
ceiling killed it. Measured on a reproduction: a hook posted 0.5s behind a wedged one took **19.5s** to
return.

- ✅ **Delivery moved off the accept thread, onto a SERIAL queue.** Serial, not concurrent: hook events are a
  per-pane state machine (`UserPromptSubmit → PreToolUse → Stop`) and arrival order is meaning. A slow sink
  now delays only its own delivery, never the next client's POST.
- ✅ **`SO_RCVTIMEO` on each accepted connection.** A peer that connects and never writes used to park the
  drain `read` forever. The ceiling now exists (2s).
- ✅ **`nc -U -w 2` in the hook script.** Belt to the host's braces: a wedged host costs seconds, never the
  timeout. It stays SYNCHRONOUS on purpose — backgrounding the relay would let two `nc` processes race and
  deliver `Stop` before the `PreToolUse` it follows.
- ✅ **The one socket-binding test in the suite.** `testAWedgedSinkDoesNotBlockTheNextClient` binds a real
  socket in a temp dir and asserts the CLIENT's contract (a POST returns promptly while a sink is wedged),
  because the sink-side delay is deliberate. Hang-proof: every wait is an expectation with a timeout, so a
  regression fails instead of hanging the suite. Mutation-checked — it fails in 3.7s against the inline
  `onRecord?(record)` it replaced.

→ touches `AgentHookListener.swift`, `AgentInstaller.hookScript()`. An already-installed hook script is
stale until the host reinstalls it (or it is edited in place).

## The switcher is measured against its window, and the walk is a LOOK (2026-07-31)

Two asks on the round-3 card: it read too narrow, and ⇥ should show the tab it is passing over rather
than only the one it lands on.

### Width is a band, not a constant

The card was a fixed 460 — the app's dialog rung. Wrong instrument: a dialog's content is authored and
fits by construction, while this card carries LIVE text of wildly varying length. The band was MEASURED
in the row's own anatomy (SF 13, ~90pt of chrome: card + row padding, the keycap and its gap):

| content | card | what lands there |
|---|---|---|
| 45 ch | 390 | the low end of a comfortable measure |
| 60 ch | 490 | `swift test --filter TabSwitcherRowsTests` |
| 75 ch | 590 | the high end; past it the eye loses the line |

- ✅ **`clamp(400, 0.42 × window, 640)`, then never more than 2/3 of the window.** 400 shows a real
  command untruncated; 640 is the app's widest list rung (Open Quickly) and the point past which a line
  stops being scannable. ⚠️ The last clamp OUTRANKS the floor: on a narrow window the minimum would draw
  a card wider than its host, and an overlay that fills its window has stopped being an overlay.
  HW-verified at three regimes — 820 → 400 (floor), 1280 → 538, 1600 → 640 (cap).
- ✅ **Height is capped at 0.7 of the window and the rows scroll**, with the highlight kept in view. A
  session with more tabs than the window is tall previously drew a card taller than its host.

### The walk previews the tab it is over (`controls.tabSwitcherPreview`, default ON)

⚠️ This does NOT relax the switcher's founding rule that the highlight is LOCAL. A tab focus is a
host-owned intent, and staging one per step would broadcast every intermediate tab of a cycle to every
other client on the workspace.

- ✅ **The preview rides `DeviceFocus`** — the same device-local overlay an unfollowing device lives on
  (docs/45 §8.2). It writes no intent, publishes no presence (that rides `reconcileTree`, which the
  preview never calls), and is unwound on BOTH exits. The commit still stages exactly once, and it is
  unwound BEFORE that commit so `selectTab` publishes focus from the state the gesture began with.
- ✅ **Cheap by construction:** `SplitContainer` renders every tab of the active session and merely hides
  the inactive ones, so a preview step is a visibility flip, not a mount.
- ✅ **The toggle is real, and the OFF case is a legitimate mode, not a broken product** (the flags
  criterion): the preview flips a VIDEO pane's UDP/VT/Metal pipeline on and off as the walk passes, and
  some people want the workspace to hold still. Filed under Appearance → Tabs and in All Settings.
- ⚠️ **Three existing tests pinned the behaviour this replaces** — they read `store.tree` (the projection
  WITH this device's overlays) to assert "nothing was committed". They now assert host truth
  (`workspaceMirror.topology`), which is what that sentence always meant; the preview legitimately moves
  what the device is LOOKING at.

→ touches `TabSwitcherOverlay.swift`, `TabSwitcherRows.swift` (new `TabSwitcherMetrics`),
`WorkspaceStore+TabSwitcher.swift`, `SettingsKey`/`AllSettingsCatalog`/`PreferencesStore` (+ both
Settings surfaces). New ladder rung `Slate.Metric.heightRowTall`. No wire change (golden byte-identical).

## The switcher's unit is the PANE, and so is the ⌘-digit (2026-07-31)

⌃⇥ walked TABS and ⌘1…⌘9 selected tabs, while every other surface in the app counts PANES: the sidebar
lists panes, a notification points at a pane, `⌘]`/`⌘[` cycles panes, the window title names a pane. The
container was the only thing the keyboard could reach, so ⌘3 meant one thing in the chord and another on
screen — and inside a split ⌃⇥ was a dead gesture, because a tab-keyed ring cannot tell two panes of one
tab apart.

- ✅ **One unit, one order.** `PaneSwitcher` (was `TabSwitcher`) rings PANES across the whole active
  session — every tab's panes, not the active tab's. A ring scoped to the active tab would be a switcher
  that cannot reach most of the workspace.
- ✅ **⌘1…⌘9 counts `flatOrderedPaneIDs()`** — tabs in creation order, panes within a tab in pre-order
  DFS (the walk the reconcile diff and `⌘]` already read). A split therefore renumbers what follows it,
  which is exactly what makes the number mean "the Nth pane". It lands through `revealPaneTree`, so a
  pane in a background tab brings its tab with it and that tab's badges clear on arrival.
- ✅ **The ring is PER-CLIENT** (`WorkspaceStore.paneVisitMRU`, cap 32, session-only) — tmux's
  `client->last_session`, and what docs/45 §7.3 already filed beside the latched video modes. The SHARED
  `session/focusMRU` stays tab-keyed because it exists for a different reason: close is an intent, and
  two clients computing successors from two local rings pick two different tabs. "The pane I was just
  in" is a fact about one keyboard. **No wire change** — golden byte-identical.
- ✅ **A fresh client is not blind.** Its own ring is empty on reconnect, so `paneSwitcherMRU` appends
  each remembered tab's `activePane` BEHIND the local entries — the host's recency, at the granularity
  the host has it. `candidates(active:mru:ordered:)` dedupes, so the overlap costs nothing.
- ✅ **Recorded at the ONE choke point**, `stageFocus(tab:)` / `stageFocus(pane:)`, which every
  deliberate navigation already passes through. The preview writes `DeviceFocus` directly and so records
  nothing — a walk must not reorder the ring it is walking.
- ⚠️ **A TAB rename no longer names a row.** The old builder let `tab.title` outrank the pane's live
  identity; with a row per pane that is the container's name stamped on each of its contents — the exact
  shape of the bug this builder was written to fix. The row keeps the pane's own chain, which is also
  what the sidebar shows for it. The note loses its "3 panes" segment for the same reason: it described
  the row's neighbours.
- ⚠️ **`goto_tab:N` keeps its name** and now resolves to `pane.select.<n>`. The name is Ghostty's, not
  ours; a config asking for "the Nth thing" gets the Nth thing this workspace counts.

The positional gestures are untouched and stay independent: `⌘⇧]`/`⌘⇧[` still steps the tab BAR, `⌘]`/
`⌘[` still walks the active tab's split tree. ⌃⇥ is the only recency walk, and now it can reach
everything.

→ renames `TabSwitcher`→`PaneSwitcher`, `TabSwitcherOverlay`/`TabSwitcherRows`→`PaneSwitcher*`,
`WorkspaceStore+TabSwitcher`→`+PaneSwitcher`; `.selectTab(Int)`→`.selectPane(Int)` and
`.tabSwitcher`→`.paneSwitcher` (binding ids `pane.select.<n>` / `pane.selectN` / `pane.switcher`, all
moved to the Panes group); `controls.tabSwitcherPreview`→`controls.paneSwitcherPreview`.

### The walk turns the contrast up, and only for the walk

⚠️ Dimming the unfocused panes as a RESTING treatment was tried and removed — it washed out live content,
and a pane you are watching a build in must not be half-erased because the cursor is elsewhere. Focus at
rest adds a mark to the subject (`PaneFocusCorner`) instead of subtracting from everything else.

A ⌃⇥ walk is the opposite case, which is why this is not a reversal of that: for the length of a held
modifier the whole screen is answering "WHICH pane am I about to land on", the answer changes on every
tap, and a 10pt corner marker 900pt away is not something the eye finds in 200ms.

- ✅ **`PaneRecedeScrim` on every pane but the subject, while `paneSwitcher != nil`.** The subject is the
  pane `isFocused` already names, so it works on BOTH settings of the preview: with it on the focus IS
  the highlight, with it off the lit pane is where a cancel would leave you. Exactly one pane of the
  visible tab stays lit either way.
- ✅ **0.72 over `Slate.Surface.face`** — theme-directed by construction (sinks on dark, washes on light).
  ⚠️ MEASURED, not picked: at 0.55 a light theme's black text only reached mid-grey — a real difference
  that was not findable at a glance, which is the one thing this has to be.
- ✅ Non-hit-testing, kept in the tree at opacity 0, faded with `Slate.Anim.smallFade`. A click during a
  walk still abandons the switcher and focuses the pane under the cursor — the escape must not be veiled
  shut.
- ⚠️ The predicate is trivial alone, so the TEST drives a live store and evaluates the same two calls the
  view makes (`showsSwitcherRecede` × `SplitContainer.isPaneFocused`) — what can break is the JOIN.

→ new `PaneRecedeScrim.swift`, one overlay + one static gate in `PaneContainer`.

### The project rides the row, and the row grows a second line (2026-07-31)

Section headers were the TAB era's shape and they do not survive the unit change. A header earns its line
only when consecutive rows share it; tabs arrived in project-sized runs, but PANES interleave — walk
between two repos and the recency ring reads `slopdesk, otty, slopdesk, otty`, which under a run-boundary
rule is a caption above almost every row. Re-sorting to repair that is worse: the card's order IS the
order ⇥ steps in, so grouping would make the highlight jump around the list.

- ✅ **Headers deleted; every row says its own place.** `PaneSwitcherItem` (the section/row display list)
  is gone — the view iterates rows directly.
- ✅ **The row is TWO REGISTERS**: the identity, and under it the place — project, then the sub-path it
  strayed into. Built as ONE `Text` so the two halves flow and truncate as a single run (head-truncated:
  a deep path's last components are the ones that say where the pane is).
- ✅ **The project is set a shade heavier than the path under it.** Weight, not ink: both halves are
  equally quiet next to the identity, so what separates them is which one the eye should catch running
  down a column. This is also what replaces the header's grouping cue — a run of rows from one repo still
  lines up down the card.
- ✅ **`Slate.Metric.heightRowStacked` (48)** — a new rung for a two-register row: ~29pt of stacked ink
  (13 over 11) plus a breath either side. It also answers the shrink the header removal would otherwise
  have caused: the same six panes now read as an object rather than a strip.
- ⚠️ **`unrepeated` had to learn the note.** With the path on the row, a shell deep in a project titles
  itself by the folder-name rung and the row reads `Overlays` over `slopdesk › …/Overlays` — the same
  stutter the project rule already caught, one level down. It now yields to the pane's program when the
  title matches EITHER the project or the note's last component. Photographed before and after; only the
  LAST component counts, since a match higher up the path does not read as a repeat.
- ⚠️ Aesthetic choice made from PIXELS: three anatomies were built for real and rendered side by side
  over a mock terminal (stacked / stacked + leading glyph / one line with the place trailing). The glyph
  column was dropped — every pane is a terminal, so it repeated a mark that said nothing.

→ `PaneSwitcherRows` loses `items`/`PaneSwitcherItem` and renames `header`→`projectName`;
`PaneSwitcherOverlay` loses `SectionHeader` and rebuilds `RowView`.

### Every overlay is the switcher's card (2026-07-31)

The ⌃⇥ switcher's card is the surface the user actually likes, so it stops being one overlay's private
styling and becomes the vocabulary the whole floating set speaks: the command palette, Open Quickly,
global search, the keyboard cheat sheet, Connect to Host, Peek & Reply.

Before this they were native `.sheet` bodies under the "everything outside the workspace is native chrome"
directive (2026-06-30) — a grouped `Form`, a `List` with section backgrounds, per-glyph shortcut chips, an
opaque system panel. That directive is narrowed, not reversed: Settings and the close-confirmation `.alert`
stay native, because they ARE system surfaces. The command surfaces are workspace furniture, and reading
like System Settings is what made them look unrelated to the window they float over.

**The four moves — this is all "the switcher's style" is.**

- ✅ **The SURFACE is glass with a rim and a cast shadow**, never an opaque box. Extracted from the
  switcher to `SlateGlassCard` + `Slate.Metric.panelShadowRadius`/`panelShadowY`.
- ✅ **No chrome inside it.** No grouped-`Form` insets, no `List` section fills, no system `Divider`s
  between static regions. The single allowed line is `SlateCardSeparator`, and only where content MOVES
  past content (results scrolling under a query field). This is the move that makes the set look related.
- ✅ **A selected row is a PLATE** — one surface rung up, hairline-bordered (`slateSelectionPlate`) — and
  its title goes heavier, never coloured. In global search the pointer IS the selection, so hover takes
  the same plate.
- ✅ **A pressable key is a KEYCAP** (`SlateKeycap`), one cap per CHORD rather than one per glyph: the
  modifiers are a single gesture, and a row of little boxes reads as four things to do.

**⚠️ `.presentationBackground(.clear)` does not clear a macOS sheet.** Photographed: the palette rendered
as a card nested inside a second, larger, white panel. It clears the SwiftUI-drawn ground while the sheet's
`NSWindow` keeps painting its own and casting its own shadow. `slateClearSheetWindow()` reaches the window
(`isOpaque`, `backgroundColor`, `hasShadow`); BOTH modifiers are required. The sheet is kept for what it is
genuinely good at — modality, key focus for the text fields, Esc/click-away routing through the existing
binding — and stripped of everything it draws.

⚠️ **The card title is one rung ABOVE a section header** (`footnote`/`secondary` vs `small`/`tertiary`).
The first cut set both alike and was photographed: on the connect card `CONNECT TO HOST` and the `HOST`
label under it were the same size, ink and voice — the card's name read as a third field label.

⚠️ **The cheat sheet packs COLUMNS, not a grid.** `LazyVGrid` pairs sections into grid rows, so a short
category is centred against the long one beside it and floats halfway down the card. `columnAssignment`
deals sections greedily into the shortest column, balanced by rendered height (rows + header line), and is
pure so `CheatSheetColumnBalanceTests` pins it without a view.

→ New `DesignSystem/SlateOverlayCard.swift`; `DesignSystem/SlateSheet.swift` DELETED (both its users
converted); `PaneSwitcherOverlay` loses its private `SwitcherSurface`/`Keycap` to the shared ones.

**Follow-up, same day — three corrections from looking at it running.**

- ⚠️ **The shadow gutter was a HALO.** Padding the card inside the sheet, to give its cast shadow room, put
  a 12pt band of the sheet's OWN surface around the card: brighter than both the card and the workspace,
  and tinted by the theme's ground — clearly violet on Monokai Classic. Neither
  `.presentationBackground(.clear)` nor clearing the `NSWindow` stops the sheet painting that surface; the
  only thing that hides it is sizing the window exactly to the card. So the padding is gone and the cast
  shadow with it — the rim carries the card alone. (Re-enabling the window's own shadow does not help: the
  sheet's surface makes the window's alpha a full rectangle, so it would cast a rectangular shadow around
  a rounded card.)
- ⚠️ **The tint goes back to SYSTEM.** Theme-accenting the stock buttons was tried and rejected on sight:
  a recoloured system button reads as a recoloured system button, not as workspace furniture.
- ⚠️ **The controls inside a card stay NATIVE.** A hand-drawn field plate is thinner than a real macOS
  field and reads as cramped, so Connect-to-Host and Peek & Reply use `.roundedBorder` at `.large`. The
  card supplies the SURFACE and the labels around the controls; the controls themselves are the system's.
  `slateFieldPlate()` survives for global search's search bar, which is a search bar, not a form field.

**Follow-up 2 — the cards leave the sheet, and the ink leaves the terminal.**

Three more reports from running it: a white border flashing as a popup opened and vanishing once it
settled; a radius and edge less elegant than the switcher's; and no liquid glass behind them at all.

⚠️ **One cause: a sheet is its own WINDOW.** `glassEffect` refracts what is behind the view WITHIN its own
backdrop, and a second window has nothing behind it — the material silently degrades to a flat fill
(measured: every interior pixel of the sheet-hosted card was one dead value, where the in-window card's
vary with the terminal beneath). The same window painted its own surface across its whole frame, which is
the pale frame on open AND, when the card was inset for its shadow, the violet halo of the round before.
And its mask clipped the corner to the system's radius rather than `radiusPanel`.

Substituting a behind-window `NSVisualEffectView` was built and rejected on sight: a different material
reads as a cousin of the switcher, not as the same object. **There is no separate-window arrangement that
matches an in-window glass card.** So the cards are presented the way the switcher is — a centred
`.overlay` in the workspace window — and the sheet is gone.

⚠️ **`.onTapGesture` DOES NOT FIRE on that layer.** The workspace is an AppKit split
(`NSViewControllerRepresentable`) and its real `NSView` wins `hitTest:` against SwiftUI content drawn over
it, so SwiftUI's gesture recognition never sees the click. A real control does: measured both ways in one
session — a row backed by `.onTapGesture` ran nothing while the connect card's native Cancel button, in the
same overlay at the same moment, dismissed the card. Anything clickable on these cards is now a `Button`
(`SlateClickTarget`, laid over the finished row so its layout is untouched); the dismiss backdrop is one
too. Verified on hardware: a palette row click splits the pane, a click outside closes the card.
⚠️ Hover-select does not survive this (`onContinuousHover` is a gesture) — keyboard selection and clicking
both do.

**The ink is NEUTRAL, not the terminal's** (`SlateOverlayInk`). Monokai's greys are tinted — Classic's are
violet, Ristretto's warm rose — and a dialog wearing them reads as a stained panel rather than a neutral
surface over coloured work. Every overlay colour now derives from `Color.primary` or the system accent, so
it is a true grey on both appearances; `Slate` still supplies dimension and the mono face. The workspace
keeps the filter. Status colour is the exception and stays: neutrality is about chrome not competing, never
about suppressing a signal.

**Follow-up 3 — the card behaves like a card: it swallows its own clicks, hands the keyboard back, and
follows the mouse.**

Four reports, three of them the SAME root as each other and one a self-correction of the round above.

⚠️ **A dismiss floor that spans the window is reachable THROUGH the card.** Clicking a card's own body —
a label, the padding between two fields, the gap beside the "Video ports" disclosure — hit nothing
interactive, fell to the backdrop button beneath, and dismissed the card the user was reaching into. The
card now carries its own hit barrier (a clear `Button` BEHIND its content, inside `slateGlassCard()`), so
every real control still takes its hit first and only what the content declines stops there. The
disclosure row also became full-width (`Spacer` + `contentShape`) — a hit area two words wide is a miss
waiting to happen. Verified: an inside-click leaves the card up, "Video ports" expands, a click outside
still closes.

⚠️ **An in-window card must hand the KEYBOARD back on close.** The card's field is the window's first
responder while it is up, and tearing it down leaves the WINDOW holding it, so the pane went deaf until it
was clicked. None of the surface's reclaim paths fire — they gate on a focus TRANSITION or a click, and
the workspace focus never changed. A sheet did not need this (AppKit restored the parent window's
responder); the fix is `WorkspaceStore.reclaimKeyboardFocusInActivePane()` on the card's `onDisappear`,
the same hand-back the find bar performs, resolved against whichever pane is active AT THE CALL (so a
palette split leaves the keyboard on the pane it created).

⚠️⚠️ **CORRECTION to Follow-up 2: `.onTapGesture` was never the problem — `allowsHitTesting(false)` was.**
The dead palette row was the ambient layer's hit gate suppressing everything composed into that chain,
which the same commit fixed by making the modal a ZStack SIBLING. `SlateClickTarget` was added in that
commit too and wrongly credited. Worse, it caused a regression: a click target laid OVER a row is topmost
for the pointer, so it ate the row's `onContinuousHover` and hover-select stopped working on the palette
and Open Quickly. A row is now a real `Button` WRAPPED around itself (`slateRowButton`) with the hover
modifier outside it. Measured on hardware: hover moves the selection on both surfaces, and the click still
runs the row. `SlateClickTarget` survives as the dismiss floor only.
⚠️ Automation trap: a cursor WARP (`CGWarpMouseCursorPosition`, what most drivers do) posts no mouse-move
event, so tracking areas never fire and hover looks broken. Move with real `CGEvent` moves (`cliclick m:`).

**A held arrow now WALKS the list** (`OverlayKeyRepeat`). `.onKeyPress` subscribes to `.down` only unless
asked, so every card list moved once per physical press. Repeat is a WHITELIST — the pickers route their
whole keyboard through one handler, so a held ⌘3 would otherwise re-open the third row every 30ms; the
movement keys repeat and everything else's repeats are swallowed (`.handled`, not `.ignored`, which beeps).
⚠️ Automation trap: `postToPid` drops synthetic auto-repeats. Post to `.cghidEventTap` with
`kCGKeyboardEventAutorepeat = 1` (proved on a held letter first: 1 down + 6 repeats ⇒ 7 characters).

**The SYSTEM ACCENT leaves the family too.** Neutral in Follow-up 2 meant "not the terminal's filter"; it
now also means "not the machine's accent". The caret, the fzf match run, the ✓ gutter and the default
button were the last coloured things on an otherwise monochrome card, and one blue (or, on another Mac,
pink) element makes it read as a system dialog wearing our surface. A match run is marked the way every
readout here marks importance — heavier, against quieter neighbours — and a filled control takes
`SlateOverlayInk.control` (grey, because the platform draws a filled control's label white on both
appearances, so a `primary` fill would be white-on-white in dark mode).
⚠️ The native focus RING stays the system's blue: it is drawn from `NSColor.keyboardFocusIndicatorColor`,
which `.tint` does not reach, and the only ways out are killing the ring or repainting the whole app's
accent — both worse than one blue ring on a focused field.

## The app ships ONE neutral accent, and the overlays ship one component kit (2026-07-31)

Three reports against the connect card, photographed on hardware: the field ring was still machine-blue,
the Connect button rendered as a near-white plate, and its white label vanished into it. All three were
the residue of chasing neutrality with per-subtree `.tint()`:

- The blue was `NSColor.keyboardFocusIndicatorColor` (and the text-selection wash) — AppKit derives both
  from the APP's accent, and no `.tint()` on any subtree reaches them. The round above called repainting
  the app accent "worse than one blue ring"; with the ring now reported alongside a tinted-button bug, the
  trade reversed.
- The white-on-white button was `.tint(SlateOverlayInk.control)` (a flat `Color.gray`) on
  `.borderedProminent`: in dark appearance the platform lightens that tint into a near-white plate and
  still paints the label white. A hand-picked tint bypasses the platform's own label-contrast logic; an
  ACCENT does not.

**The fix is the supported mechanism: an `AccentColor` asset** (`Apps/Shared/Assets.xcassets`, wired by
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in both app specs) carrying a per-appearance graphite
(`#8E8E93` light / `#6E6E73` dark). Focus rings, text selection, filled controls and the close-confirm
`.alert` all resolve neutral on every theme, on both platforms, with the platform still choosing label
contrast. Verified by pixel on light + dark: no blue anywhere on the card, and the Connect label is
legible on a graphite plate.

With the accent itself neutral, every tint correction became dead weight and was DELETED: the WindowGroup's
`.tint(Slate.State.accent)` (and the satellite copy), the overlay layer's `.tint(nil)`, the Settings
scene's `.tint(nil)`, the first-launch sheet's `.tint(nil)`, and `SlateOverlayInk.control` itself. Where
the THEME accent is a deliberate signal (active tab, the focus corner, the rail), the view names
`Slate.State.accent` explicitly — the accent is now an ingredient views ask for, never an ambience they
must undo. The terminal cells and the status colours are untouched.

**The overlays now compose ONE component kit** (`DesignSystem/SlateOverlayControls.swift`) instead of
hand-rolling the same shapes: `SlateCapsLabel` (the section-level caps micro-label — palette headers, Open
Quickly headers, cheat-sheet categories, field names, Peek & Reply's RECENT), `SlateLabeledField` (caps
label over a NATIVE `.roundedBorder`/`.large` field), `SlateSearchBar` (magnifier + plain field at
`heightInput`, with the deferred focus-grab handled once), `SlateCardFooter` (Cancel + prominent confirm,
standard padding), and `SlateWarningRow` (the amber status line). Peek & Reply's off-grid literals (20/14/
12/24pt paddings, its own 460 width) moved onto the `Slate.Metric` grid, and the form-card width became a
token (`cardFormWidth`), so the connect and peek-reply cards are the same object at the same size. The
rule stands as before — the card is ours, the controls in it are the system's — this round just makes
"ours" one vocabulary instead of six dialects.

## A form card's title is a real title, and its labels speak sentence-case (2026-07-31)

The connect card was reported "not beautiful, not modern" with the complaint aimed at its TITLE and
LAYOUT. The card was wearing the instrument voice head to toe: `CONNECT TO HOST` in tracked caps-mono,
`HOST` and `PORT` in the same register right under it — three runs of engraving stacked on one small
form. Research across the current crop of macOS dialogs (Apple's Tahoe HIG alerts/panels, Linear,
Raycast, Things 3) agrees on the opposite grammar: a short sentence-case noun-phrase title one size up
from the body, sentence-case field labels, and NO caps eyebrows anywhere in a form.

So the floating family's hierarchy is now SIZE AND WEIGHT in one voice, not a voice-switch:

- **`SlateCardTitle` is a real title**: the system face at the new `Slate.Typeface.title` rung (15) at
  semibold in `primary` — the one line on a card that outranks the content it names. The caps-mono
  treatment is deleted.
- **`SlateLabeledField`'s label is sentence-case** system text (`base`/medium/`secondary`), not a caps
  micro-label. `SlateCapsLabel` survives ONLY as a LIST region's caption (palette / Open Quickly
  section headers, cheat-sheet categories, Peek & Reply's Recent) — naming a run of rows is the one
  place the caps register still earns its keep, and those surfaces were the ones already judged good.
- **A port field is port-sized**: host + port share one row (`portFieldWidth` = 96), as do the two
  video ports behind the disclosure — a five-digit answer no longer gets a card-wide question. Three
  variants were built for real and photographed (title-first / Linear-compact 13pt / title-less
  placeholder-as-label): the title-less cut died on contact with reality — this card opens PRE-FILLED
  with the live target, and a filled field with no label says nothing about what it is.

The cheat sheet inherits the same real title through the shared component. Peek & Reply keeps its own
header (the agent pane's title IS that card's identity — it was already content-first) and the
search-led overlays (palette / Open Quickly / global search) were never titled at all.

## The notification card joins the floating family: glass, sentence-case headline, one filled status mark (2026-07-31)

The in-app notification was reported disliked WHOLESALE — no part of the previous round's design
survived contact with the new floating-family grammar. It was the family's last opaque outlier: a
coloured caps-mono EYEBROW (`DONE · Claude`, `NEEDS INPUT · Claude`) over a mono subject on a
`Surface.raised` plate, which after the form-card round read as four hues of instrument engraving
stacked in a corner. Research (Warp's `ex-toast` — the closest analog, a terminal speaking 14px
sentence-case in ONE voice; Linear's toast tokens; Sonner's neutral-card default; HIG/`hudWindow`
restraint) agrees the modern in-app toast is a quiet neutral card, sentence-case, with at most one
small semantic accent.

- **The card is the family's glass card** (`slateGlassCard(hitBarrier: false)`) with the neutral
  system ink — the same object as the switcher/palette/connect card. The barrier is OFF because the
  toast's whole body is already its jump button; a background barrier would eat the clicks the card
  exists to take (measured against the modal cards, where the barrier is load-bearing).
- **The eyebrow's words became the HEADLINE**: a sentence-case event phrase derived from
  source + flavour + title ("Claude needs input", "Claude is done", "make check failed",
  "make check finished") — the two-speakers bit lives on, it just picks a VERB now instead of a caps
  word. Notices/advisories pass their title through untouched (the title IS the message). Factories
  override with a truer phrase where the derivation can't reach ("Session reattached" /
  "Reconnected to a fresh shell"). The long-command fallback title became the verb-less "Command" so
  the derivation can append the outcome without doubling.
- **The leading mark is ONE filled SF family** (`*.circle.fill`) in the status hue — checkmark/xmark/
  exclamationmark, `info` NEUTRAL (cyan on every routine OSC notice was chrome pretending to be
  signal). Three variants were photographed in the real window: the filled-symbol card won; a 6px
  status dot re-committed the "tiny abstract speck" mistake that killed the rail's ring here, and a
  no-mark card was elegant but blind — every card read identical until parsed, forfeiting the one
  signal (status colour) the neutral family explicitly keeps. This does NOT re-run the rejected
  SF-symbol quartet of two rounds ago: that was four glyphs from four families at four stroke
  weights; this is one family, one size, one weight.
- **Behaviour is untouched**: card-is-a-door jump, dwell pause-on-hover with nothing drawn,
  hover-only ✕ (unconditional on sticky), the 2-expanded spine, epoch-keyed dwell restart.
- **Photographing it**: the glass surface is a GPU backdrop effect `ImageRenderer` cannot rasterise,
  so the gallery tests judge layout/type/marks only. `SLOPDESK_TOAST_DEMO=1` seeds a sticky demo
  stack in the shipping app for real-window shots — that seam is the new judging surface.

## The command palette learns the panes: ⌘⇧P searches jump rows too (2026-07-31)

E11 scoped ⌘⇧P to verbs-only and sent every jump-to to Open Quickly (⌘⇧O). That split kept the
taxonomy clean but taxed the muscle memory every other tool trains: in VS Code / Zed the ⌘⇧P box
is where you type the name of the thing you want, verb or not. Reaching for a pane in the palette
and finding only verbs was a dead end that cost a re-open on the other chord.

- **The ⌘⇧P mixer now registers `TabsPaletteSource`** (the pane-jump source that had no surface
  since E11 folded jump-to into Open Quickly): one row per open pane of the active session,
  snapshotted per open like the Move-Pane verbs, accept = `jumpToPaneTree` and close. The section
  is titled **Panes** (the switcher's unit — the row is a pane, not a tab), registered AFTER the
  verb categories so an action title always outranks a pane row on a shared query.
- **The zero-state lists the open panes** under the Panes header after Move Pane, so the palette
  doubles as a pane switcher before a query narrows it.
- **Pane rows carry their cwd/app-name as a rendered subtitle** — the palette row view now shows
  a subtitle in the secondary ink (head-truncated, so a squeezed path keeps its leaf), because
  every fresh pane is titled "Terminal" and title-only rows would render indistinguishable twins.
- **Open Quickly is unchanged** — it keeps the richer multi-source jump-to (recents / folders /
  agents / files / command index). ⌘⇧P panes is the low-ceremony subset: the open panes, in the
  box people already have under their fingers.

## A pane is named once, and the chrome learns the terminal's alphabet (2026-07-31)

Two reports against the day-old ⌘⇧P Panes rows, one root cause each:

- **The palette named panes by `liveProgramTitle ?? spec.title` while the ⌃⇥ switcher resolved
  the full identity chain** (`RailRowsBuilder.liveRowTitle` — rename → intent → running command →
  stripped program title → process → blocks → folder), so the same pane wore two names two
  keystrokes apart. Fixed by extracting the switcher's per-pane resolution as
  `PaneSwitcherRowsBuilder.identity(pane:spec:tab:store:)` and pointing `TabsPaletteSource` at it:
  the palette row now carries the switcher's title verbatim and its PLACE line (`project › note`)
  as the subtitle, with the raw cwd demoted to a hidden search keyword so full-path queries still
  land.
- **A nerd-font glyph in a title drew as a notdef dot.** Private-use codepoints have no system
  fallback BY DESIGN — only the terminal grid could draw them, because ghostty embeds a symbols
  face. The app now bundles that SAME face (`SymbolsNerdFont-Regular.ttf`, MIT, licence beside it,
  ~2.4 MiB) as a `SlopDeskClientUI` package resource, registered process-wide on first use.
  `Text.nerdAware(_:size:)` splits a string into private-use vs ordinary runs (pure, unit-pinned)
  and splices ONLY the symbol runs into the bundled face — ordinary titles stay plain `Text`,
  byte-identical to before. Adopted by every chrome surface that renders live titles: the sidebar
  row, the ⌃⇥ switcher (title + place), the ⌘⇧P palette (fzf highlight runs + subtitle), and
  Open Quickly's highlight.

### The agent mark returns to the title — normalized, never animated (2026-07-31)

The follow-up ask: stop STRIPPING the agent glyph now that the chrome can draw glyphs. The strip
existed for a real reason — the leading glyph is the agent's SPINNER (braille frames, the `✢✳✶✻✽·`
asterisk cycle), and keeping the raw frame means the title's text changes on every animation tick:
the row-flash bug (`e551dc0b`) and the R23 no-motion-on-text rule both trace to exactly that. So
`strippedProgramTitle` became `normalizedProgramTitle`: every frame of the spinner family maps to
the ONE static `✳︎` mark ("⠙ build" / "⠹ build" / "✻ build" → `✳︎ build`, pinned identical), other
leading symbols stay user content, a bare glyph still carries no title. The mark shows; nothing
moves. The sidebar row's own `✳` agent marker skips itself when the title already leads with one.

## The right sidebar returns as the CODE panel: project-scoped embedded VS Code (2026-08-02)

> User-directed: "làm triệt để theo hướng code-server + WKWebView … mở lại cái right sidebar mà
> ngày xưa mình bỏ đi … project-scoped — các pane trong cùng 1 project show chung 1 cái vscode mở
> sẵn folder là project đó." RE-SCOPES the Host Windows rail retirement's "no right sidebar" state
> (the full-desktop pivot removed the rail, not the slot).

- ✅ **Embedding approach = code-server (Coder, MIT) in a WKWebView — decided by research + spike.**
  The official `code serve-web` / VS Code Server EULA forbids embedding in third-party apps and the
  marketplace ToU is restricted to official products; openvscode-server is frozen (22 versions
  behind); monaco-vscode-api has no full-workbench-in-WKWebView precedent; window reparenting is
  impossible on macOS. code-server ships the full workbench (Open VSX extensions), and the spike
  proved the service worker + full workbench run in a plain third-party WKWebView at
  `http://127.0.0.1` with no special entitlements.
- ✅ **The host owns the code-server lifecycle: metadata verb 18 `ensureCodeServer` NEVER waits.**
  `CodeServerManager` (one child per canonical project root) spawns `code-server --auth none
  --bind-addr 0.0.0.0:0` and learns the ephemeral port from the announce line (the cmux port-0
  pattern — no allocation race); the RPC replies with the CURRENT state (`starting`/`ready`/
  `unavailable` + port) immediately because a cold Node boot is multi-second and the metadata
  channel times out at 5s — readiness is CLIENT-side polling. `--idle-timeout-seconds 7200`
  self-reaps; a dead child respawns on the next ensure; `HostServer.stop()` terminates all.
  No auth token: the WireGuard mesh IS the security boundary (the no-app-layer-auth invariant).
- ✅ **The panel is the third plain `NSSplitViewItem` — the Host Windows rail's anatomy, revived.**
  Navigator | content | CODE. A PLAIN item, never `.inspector` (its collapse unmounts the hosted
  view — the exact reason the rail entry pinned this), so a collapse just unparents while the
  webview survives. ⌘⇧R (the chord the rail held, freed by its retirement, deliberately re-taken —
  `E1KeymapParityTests` re-pinned) toggles it via `.toggleCodeSidebar` through the standard
  closure chain (route → dispatcher/menu/palette → `WorkspaceChromeState.codeSidebarCollapsed`).
  Default COLLAPSED; the flag persists (`Defaults[.codeSidebarCollapsed]`) — unlike the left
  panel's session-scoped collapse, opening the code panel is a workstyle choice.
- ✅ **Project-scoped = keyed by the host-pushed `projectKey`, one warm webview per project.** The
  ACTIVE pane's `paneProjectKey` (wire type 34 — the SAME key the sidebar sections group by, and
  the absolute host path `CodeServerManager` canonicalizes) picks the workbench; every pane of one
  project shares the ONE instance opened at `?folder=<root>`. `CodeSidebarWebViewPool` keeps one
  WKWebView per project for the app's lifetime (cmux keep-alive lesson): switching projects is a
  warm swap, not a workbench reboot. `CodeSidebarModel` (pure, unit-pinned) owns the poll loop +
  URL build; the collapse unmounts the column so the poll only runs while the panel is open — a
  code-server is only ever ensured on first expand.
- ✅ **Keyboard: the dispatcher YIELDS to the webview (the cmux collision lesson).** The NSEvent
  monitor preempts the responder chain, and VS Code's chord vocabulary (⌘P/⌘⇧P/⌘F/⌘S/⌘W/⌘1–9)
  collides with the workspace table wholesale — so while the code panel's webview holds first
  responder every chord passes through UNCHANGED (the shortcut-less menus mean nothing else claims
  it en route; system ⌘Q stays alive via the app menu). The ONE exception: ⌘⇧R stays app-owned —
  closing the panel is how the keyboard comes back. Pinned by `DispatcherCodeSidebarYieldTests`;
  literal-byte text bindings sit BELOW the yield (they target the terminal, never an editor).

### The leftovers closed the same day: no fallback ensure, no focus steal, no light workbench (2026-08-02)

- ✅ **The ensure gate is the HOST-pushed key ONLY — the cwd fallback may section, never spawn.**
  The first pixel run showed TWO code-server children for one project: the panel had ensured on
  `paneProjectKey`'s cwd-fallback leg before the type-34 push landed, spawning a workbench for the
  shell's start directory that nothing would ever use again. `CodeSidebarColumn` now reads
  `WorkspaceStore.hostPushedProjectKey(_:)` (the pushed-only accessor, made public and pinned by
  `ProjectKeyStoreTests`): a client-side GUESS must never cost the host a Node process. Until the
  push lands the column shows a brief "Resolving project…" spinner (`paneProjectKey` non-nil
  proves a key is coming); a pane with no identity at all still gets the no-project placeholder.
- ✅ **VS Code cannot STEAL the keyboard — it can only be handed it by a click.** The workbench
  focuses its own editor on load/file-open/layout change, and WebKit forwards each page `focus()`
  as a first-responder claim — an autofocus mid-keystroke would silently re-route the terminal's
  keyboard into the editor (the cmux focus-steal lesson, now ported). `CodeSidebarWKWebView`
  (the pooled class) refuses `becomeFirstResponder` unless the CURRENT event is a mouse-down
  whose location falls inside the webview; the decision is `CodeSidebarFocusPolicy` (pure,
  truth-table-pinned — programmatic claims arrive with no current event and are refused, as is
  any claim riding an unrelated key/scroll/hover event).
- ✅ **First-run workbench defaults are SEEDED host-side, never overwritten.** A pristine host
  rendered VS Code's stock light theme against the dark chrome. `CodeServerManager` now writes
  `{"workbench.colorTheme": "Default Dark Modern", "workbench.startupEditor": "none"}` to the
  code-server user settings (`$XDG_DATA_HOME`/`$HOME/.local/share` + `code-server/User/
  settings.json`) ONLY when the file is absent — an operator's own settings are untouchable
  (`.withoutOverwriting` backstops the exists-check) — once per manager lifetime, before the
  first child boots (after that a seed would need a reload to take). Trap pinned in the tests:
  "home" must be resolved `$HOME`-first like the Node child's `os.homedir()` — `NSHomeDirectory`/
  `homeDirectoryForCurrentUser` go through directory services and ignore a `HOME` override, so a
  gate-sandboxed hostd seeded the REAL user's file while its children read the sandbox's.

### The panel regressed the rail's chrome on its first real deploy — restored, content unchanged (2026-08-02)

- ✅ **ATS: the workbench must load over plain HTTP to a NON-loopback host.** ATS exempts only
  literal localhost, so the 127.0.0.1 gate run masked a silently blank webview on every real
  address. `NSAllowsArbitraryLoads` is declared in `project.yml`'s `info:` block — **Info.plist is
  a PRODUCT: xcodegen regenerates it from `project.yml` on every generate** (check-macos and the
  deploy script both run xcodegen), so a direct plist edit evaporates. Security remains the
  WireGuard mesh (the no-app-layer-crypto invariant).
- ✅ **The code divider is hand-dragged — the host-rail machinery, restored.** AppKit's constraint
  drag cannot grow a trailing item that holds harder than its leading neighbour (panel 260 >
  content 250, deliberate), so the rail's tracked `setPosition` loop returns in
  `FlatDividerSplitView.mouseDown`, clamped between the content floor and the panel floor
  (`CodeDividerClampTests`; the panel floor wins over-constrained; no drag-collapse — hiding
  belongs to the toggles).
- ✅ **The rail's split of toggle duties returns**: a hover-revealed reopen plate in the titlebar's
  trailing cluster (always-reserved zero-shift slot) while collapsed; the expanded toggle inside
  the column's own traffic-light strip row; the "CODE" header in the instrument voice BELOW the
  strip. The `</>` glyph replaces `sidebar.right` wherever the action shows a face.

### The workbench goes secure-context + lean: loopback proxy, AI stripped (2026-08-02)

> User-directed: kill the "insecure context" warning ("mình có thể setup local ssl được không?")
> and slim the workbench ("bỏ mấy tính năng AI đi, giản lược bớt giao diện đi").

- ✅ **Loopback proxy beats local SSL.** The insecure-context toast (and dead clipboard/
  `crypto.subtle`) is browser SECURE-CONTEXT semantics, not transport security — and browsers
  treat loopback as a-priori trustworthy. `CodeSidebarProxyPool` (client, macOS) binds one
  `127.0.0.1` TCP relay per project and pipes bytes to the host over the mesh; the WKWebView
  loads `http://127.0.0.1:<local>`. A self-signed `--cert` was REJECTED: it needs trust-override
  plumbing in the webview, still rotates the origin with every respawned ephemeral port, and
  reintroduces app-layer crypto theatre the WireGuard-mesh invariant exists to avoid.
- ✅ **The local port is FNV-1a-derived from the project root** (`CodeSidebarProxyPorts`, pure,
  pinned — Swift's `Hasher` is process-seeded and would break this): the workbench ORIGIN is
  stable across code-server respawns AND app relaunches, so per-origin localStorage (layout,
  view state, dismissals) finally persists. Bind collision strides to the next candidate; total
  bind failure falls back to the direct remote URL (the ATS arbitrary-loads exception stays for
  exactly this path). The relay is retargetable — a respawn moves the backend, not the origin.
- ✅ **The seed grows a LEAN profile and an upgrade rule.** v2 seed adds `chat.disableAIFeatures`
  (the whole AI/chat surface), command-center/layout-control/navigation-control off, tips off,
  recommendation nags off, minimap + breadcrumbs off; `--disable-getting-started-override` joins
  the argv. Because the seed is only-if-absent, `seedUserSettings` now also REWRITES a file that
  is byte-identical to any seed in `obsoleteSeeds` — pristine by construction (the workbench
  rewrites the file on any user edit), so this is seed evolution, not a migration; anything else
  stays untouchable. Every lean key is user-scope — flipping it back in the workbench UI sticks.

### The workbench's two side strips merge; the boot loses its white flash (2026-08-02)

> User-directed: "làm gọn luôn... cái sidebar thứ nhất, để 2 cái sidebar gộp vào nhau" + fix the
> "đen xì → trắng cái → show ra" boot sequence.

- ✅ **Seed v3: `workbench.activityBar.location: "top"`** folds the activity strip into the top of
  the primary sidebar — one column, not two, in a 380pt-min panel. Known cost, accepted: any
  non-default activity-bar location FORCES the workbench title bar visible (it inherits the
  Account/Manage buttons; upstream offers no off switch — vscode#197163), and a CSS-hide would
  leave a dead band because the part grid is JS-positioned. `workbench.secondarySideBar.
  defaultVisibility: "hidden"` joins it — the relocation had flipped the CHAT aux bar visible by
  default. v2 moved into `obsoleteSeeds` (the pristine-upgrade path reaches deployed hosts).
- ✅ **The white flash was WebKit's base canvas, killed twice over.** `drawsBackground = false`
  (the long-standing KVC key; no public macOS API) makes the canvas transparent so the dark
  column shows through, and a per-project VEIL (`CodeSidebarWebLoadState`, pooled with its
  webview) keeps the column's dark waiting surface OVER the webview from main-frame load-start
  until the navigation settles, then fades (`smallFade`). Failures also settle — WebKit's error
  page must surface, never an eternal spinner. A reload re-veils through the same delegate
  events; a warm project swap mounts unveiled. `navigationDelegate` is WEAK — the pool retains
  the observer beside the webview.

### The code panel remembers its width; the app keeps its own chords (2026-08-02)

- ✅ **`shell.codeSidebarWidth` persists the panel's dragged width** (default `0` = never dragged →
  open at the 380 minimum), written when a code-divider drag settles — the only gesture that
  changes it — and applied through the SAME clamp as a live drag at launch (`viewDidAppear`,
  panel starting expanded) and in the expand animation's COMPLETION (a `setPosition`
  mid-animation loses to the collapse animation's final frame). The left sidebar deliberately
  restores nothing (capped, session-scoped).
- ✅ **WKWebView's `performKeyEquivalent` claims ⌘-chords for the page before the menu bar sees
  them** — a focused workbench swallowed ⌘Q whole. `CodeSidebarWKWebView` now refuses the
  app/window-management set (⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘`) so those fall through to the main menu;
  everything else (⌘W = close editor tab, ⌘,, ⌘P…) stays with the editor the user deliberately
  focused. Pure `CodeSidebarFocusPolicy.isReservedAppChord` truth table, pinned — including the
  device-dependent-bits case (match the chord, not raw equality).

### One shared code-server; the workbench auto-saves and answers to SlopDesk (2026-08-02)

> User-directed: "làm triệt để cho tôi luôn đi" — ship the optimization chain the code-server
> research recommended.

- ✅ **RE-SCOPE: per-project code-server instances → ONE shared instance.** Empirically proven:
  code-server serves any folder from a single process — the workbench resolves its folder from the
  client URL's `?folder=` query (the HTML for two folders is byte-identical; the positional argv
  folder is only a default, now dropped). Per-project children were a Node runtime + extension
  host each for nothing, and they FOUGHT over the session socket (`code-server-ipc.sock` is per
  user-data-dir; only the first child owns the registry) — which the CLI's open-in-a-running-
  session routing (`code-server -r <file>`) depends on. Verb 18's wire format and validation are
  UNCHANGED (a root the host cannot see still answers `.notFound`); every root now reads the same
  endpoint. A stale child's log line can no longer poison a respawn (spawn-generation guard).
- ✅ **Client mirrors it: ONE loopback relay, one stable origin** (`CodeSidebarProxyPorts.
  sharedProxyKey`, FNV-derived port) fronting the shared instance; per-project webviews stay
  pooled — same origin, differing `?folder=`, so each project keeps its own workbench state while
  layout/storage live under one origin (standard code-server shape).
- ✅ **Seed v4: `files.autoSave: "onFocusChange"`** — the terminal beside the editor is where
  builds/tests run; leaving the editor IS the moment the file must be on disk. v3 moved into
  `obsoleteSeeds`. **`--app-name SlopDesk`** replaces the `{{app}}` branding strings.

### ⌘click on a terminal path opens in the embedded workbench (2026-08-02)

> Same directive — the third link of the chain: the code panel joins the terminal's link gestures.

- ✅ **Verb 19 `openInCodeServer`**: the "open" link action on a detected terminal PATH
  (⌘click, Hint Mode ⌘⇧J, Jump-To ↩, context-menu Open) now routes to the embedded workbench
  instead of the host's default app — `code-server -r path[:line[:col]]` lands the file (with
  cursor position) in the most recently registered workbench session. ⌘⇧click (reveal in
  Finder) and drag-drop (verb 9) are unchanged; URLs still open client-side.
- ✅ **No new detection layer.** The client already owned pure path detection
  (`TerminalLinkDetector`) and gesture policy (`LinkActionPolicy`) — the integration is one new
  `LinkAction` case (`openCodeHost`, carrying the `:line:col` suffix `resolvedAbsolute` drops)
  plus one new verb. The original plan (ghostty ABI text-at-point) was obsolete on arrival.
- ✅ **Accepted-not-completed reply + 1-byte disposition.** The workbench session registers only
  after a client webview boots — which typically happens in the same breath as the panel reveal
  this very reply triggers. So the host replies immediately (`ok` + disposition `workbench`) and
  retries the CLI async (10 × 2 s); the metadata queue never sits out a workbench boot. A
  directory, or a host without code-server, falls back to the verb-9 default-app open and says so
  (disposition `hostDefault`) — the client reveals the code panel ONLY when the file actually
  went to the workbench.

### The workbench dresses like the app: SlopDesk Monokai, sidebar right, flush top (2026-08-02)

> User-directed: dissect the Monokai Pro vsix into a SlopDesk-fit theme; workbench sidebar to the
> right; the code panel flush to the window top; a generic right-panel toggle icon.

- ✅ **"SlopDesk Monokai" = Monokai Pro with the CHROME yellows neutralized.** Dissecting the
  vsix showed its surfaces already equal the app's Slate seeds (both derive from monokai.pro) —
  the one real mismatch is the `#ffd866` UI interaction accent (active tab border/foreground,
  list selection, menus, badges…). Those ~17 keys move to the app's accent-neutral register
  (brightness, not hue: fg `#fcfcfa` / secondary / elevated; links take the filter cyan
  `#78dce8`). SEMANTIC yellows stay — `gitDecoration.modified`, find-match, syntax tokens,
  terminal ANSI — they match the app's own git ramp. Full theme JSON ships as an SPM resource
  (`SlopDeskHost/Resources`, too large for a source literal).
- ✅ **Seeded as a folder-dropped extension** (`extensions/slopdesk.slopdesk-monokai-1.0.0/`,
  package.json + theme) — empirically verified code-server recognizes it with no registry entry
  or vsix packaging. Unlike the user's settings file, the folder is OURS (namespaced) — the
  seeder repairs byte drift unconditionally. Seed v5 selects it (`workbench.colorTheme`) and
  moves the workbench sidebar right (`workbench.sideBar.location`); v4 joined `obsoleteSeeds`.
- ✅ **The code column is chrome-less.** Its strip/header died; the workbench runs flush to the
  window top (the titlebar overlay only spans the CONTENT column, so nothing collides). The
  panel's toggle + reload moved to the titlebar's trailing plates — toggle now bidirectional,
  reload speaks through a `WorkspaceChromeState` counter (the titlebar must not reach the
  column's private model). Both slots always reserved (zero-shift rule).
- ✅ **Toggle icon = SF `sidebar.right`** (palette row too), replacing `</>` — otty's actual
  lesson is "use the system vocabulary", and the right panel is a generic tab surface (code
  today, more tabs later), never a code-specific mark.

### The workbench goes fully chrome-less; fonts sync; the slopcat letterpress (2026-08-03)

> User-directed: "làm triệt để" on the workbench-UI research — ship the max-lean variant, and
> sync both the UI and monospace faces with the app, nerd-font fallback included.

- ✅ **Seed v6 = the chrome-less recipe.** Dissecting the shipped workbench bundle found the
  force-show rule: `activityBar.location` "top"/"bottom" (the v3–v5 fold) FORCES the title bar
  visible and even rewrites `customTitleBarVisibility: "never"` back to `"auto"`. The recipe
  that lets "never" stick: activity bar `"hidden"`, menu bar hidden, command-center /
  layout / navigation controls off. Status bar hidden too (its duties live app-side: the git
  readout; ⌘⇧M for problems). The panel's top edge is now the EXPLORER header itself; view
  switching is keyboard-first (⌘⇧E/⌘⇧F/⌃⇧G — chords the webview already passes through).
  Plus: compact tab height, empty-editor text hints off, overview-ruler border off,
  `window.title` drops `${appName}` ("code-server" never renders). Three variants were built
  and screenshotted; max-lean won. v5 joined `obsoleteSeeds` (verified byte-pristine after a
  real 30s workbench boot — the "never"→"auto" rewrite only fires on runtime config changes).
- ✅ **Fonts match the app on all three axes.** Workbench UI font already IS the app's (web
  default `-apple-system` → SF — nothing seeded). Editor: `ui-monospace` → SF Mono in WebKit,
  the terminal's default family, at the terminal's default 13pt. Nerd glyphs: the WebContent
  process cannot see the app's `CTFontManager` process-scope registration, so the bundled
  Symbols Nerd Font rides into the page as an @font-face data URI (~3 MB, built once per
  process) via a `WKUserScript`, and the seeded `editor.fontFamily` lists
  `'Symbols Nerd Font'` before `monospace` — agent marks and powerline glyphs render in the
  editor exactly as in the terminal chrome.
- ✅ **The empty-editor letterpress is the slopcat.** code-server's stock watermark is its own
  logo; the same injected stylesheet overrides `.editor-group-watermark .letterpress` with
  `docs/brand/logo-slopcat.svg` (ink made literal `#727072` — a data-URI SVG resolves
  `currentColor` to black — at the stock `opacity=".3"` subtlety). All builders are pure
  (`CodeSidebarPageDressing`, pinned headlessly); the WebKit wiring stays out of unit reach.

### The theme registry bug; seed v7 = registered keys only; the panel grows its own tab strip (2026-08-03)

> User-reported after living on the panel: unknown-setting warnings in the settings editor, the
> editor font not matching the terminal, the theme not applying, and no tab strip on the panel.
> All four traced to two root causes plus one design correction.

- ✅ **`extensions.json` is the source of truth — folder-dropping is not installing.** The
  batch-8 "no registry entry needed" finding held only while `extensions.json` did not exist;
  code-server writes an empty `[]` on first boot, and from then on the registry — not the
  directory scan — decides what is installed. On the real host the seeded theme folder was
  therefore INVISIBLE (`--list-extensions` empty, workbench silently fell back to stock dark —
  which is also why the font read "wrong": stock dark + pre-upgrade seed). Fix:
  `registerThemeExtension` writes our entry (identifier/version/location/relativeLocation, the
  shape the server's own validator wants) into the registry — foreign entries preserved,
  a drifted ours replaced, a missing file created. The workbench also deterministically strips
  `workbench.colorTheme` from a settings file naming a theme it cannot resolve; that mutated
  form joined `obsoleteSeeds` (byte-verified) so already-touched hosts still auto-upgrade.
- ✅ **Seed v7: every seeded key must be REGISTERED in the shipped workbench.** Code-OSS web
  ships no chat, and `window.customTitleBarVisibility` is desktop-only — the settings editor
  flags all three as unknown (the user's first complaint). A pixel-proofed variant run showed
  the title bar stays hidden without `customTitleBarVisibility`; `chat.*` dropped with it.
  Tests pin the three keys as never-return.
- ✅ **The tab strip lives on the panel, not over the terminal.** First cut put the panel's
  tab/reload/collapse in the titlebar's trailing plates (over the CONTENT column); user
  correction: "tab phải ở trên top của right sidebar" — the otty pattern puts the strip on
  the surface it controls, pushing the workbench down below it. `CodeSidebarColumn` now owns
  a top strip (`PanelTabPlate` "Code" selected + reload + `sidebar.right` collapse,
  top-anchored on the titlebar's traffic-light row so the two chrome rows read as one line);
  the titlebar keeps only the mirrored REOPEN plate while the panel is collapsed — the exact
  mirror of the left sidebar. The `codeSidebarReloadRequests` chrome relay died with the
  move: the strip calls the pool + poll model directly, in the one file that owns them.

### The panel becomes a native citizen: clipboard bridge, the terminal's own face, plate tabs, per-client light/dark (2026-08-03)

> User-reported, second round of living on the panel: copy inside the workbench never reached the
> system clipboard; the editor still rendered `ui-monospace` (not the terminal's JetBrains Mono);
> size/line-height out of rhythm with the terminal; tabs "vuông vức" — square, not the app's soft
> plate vocabulary. Plus: a light-themed client showed a dark workbench.

- ✅ **Copy is bridged natively, not permissioned.** The failure is WebKit's async clipboard API:
  `navigator.clipboard.writeText` demands a transient user activation that VS Code's async copy
  path has usually already spent, so the promise rejects silently and ⌘C dies inside the webview
  (the key event itself arrives fine — the dispatcher yield was innocent). Private WebKit
  permission prefs via KVC were rejected (crash-prone, version-locked). Instead a document-start
  user script (all frames) wraps `writeText`/`write` to ALSO post the plain text to a
  `WKScriptMessageHandler` that writes `NSPasteboard.general` directly; the original call stays
  best-effort with its rejection swallowed (a surfaced rejection would toast a false copy error).
  Copy is now deterministic on every client; paste already worked.
- ✅ **The editor face is the face the terminal ACTUALLY renders — the embedded JetBrains Mono.**
  The preference says "SF Mono" but CoreText resolves it on neither machine; libghostty falls back
  to its EMBEDDED JetBrainsMono Nerd Font. So "match the terminal" ≡ JetBrains Mono: the two
  upstream variable TTFs (upright + italic, OFL) ride in `SlopDeskClientUI` resources and inject
  as @font-face data URIs (the WebContent process cannot see `CTFontManager` registrations —
  same seam as the nerd font), and the seed's `editor.fontFamily` leads with `'JetBrains Mono'`.
- ✅ **Line rhythm is derived, not eyeballed: `editor.lineHeight: 1.32`.** JBM metrics (upm 1000,
  hhea 1020/−300/0) → ghostty `Metrics.zig` rounds cell height to exactly 1.32 × size. Seeding
  1.32 at the shared size 13 makes editor lines and terminal cells the same height to the pixel.
- ✅ **Tabs are Slate plates — geometry from the CSS coat, fill from the theme.** VS Code 1.112's
  own cornerRadius tokens already sit on Slate's ladder; the surfaces that never adopted them
  (tabs, list rows, scrollbar sliders, inputs, menus/hovers) get a geometry-ONLY injected recut
  (radius 6/8, capsule sliders, tabs inset 4px as floating plates — colours stay the theme's,
  test-pinned). Two traps: the label's stock `line-height` equals the FULL tab-height var, so the
  shrunk plate must recut it too (else glyphs overflow and the underline strikes through them —
  caught by pixel proof); and the underline containers are hidden outright — a Slate plate
  carries selection by fill. Which exposed that stock Monokai Pro flattens strip/active/inactive
  tabs to ONE colour and leans entirely on that underline: the themes now differentiate —
  active = the app's own active-tab card tone (`elevated` #403e41 dark ≡ Slate `selected` over
  the strip; white light), hover = the Slate hover tint, inactive flush with the strip.
- ✅ **The workbench follows EACH client's appearance from one shared settings file.** A second
  derived theme "SlopDesk Monokai Light" (Monokai Pro Light + the same 17-key chrome
  neutralization, pink accent → light neutrals, semantic pinks kept) ships beside the dark one,
  and seed v8 sets `window.autoDetectColorScheme` + preferredDark/Light themes. The client pins
  window `NSAppearance` to the active Slate theme, the webview's `prefers-color-scheme` follows
  it, and the workbench flips per client — a dark client and a light client on the SAME host
  each see their own register (pixel-proofed both directions in the gate fixture).

### The panel syncs the CURRENT terminal settings, and the chrome grows its seam language (2026-08-03)

> User-reported, third round: the editor's 13/1.32 are the terminal's DEFAULTS, not the client's
> CURRENT settings (macbook-pro runs 14pt / loose) — "cần sync cả current settings"; the compact
> tabs recut to 14px plates "nhìn height ngắn rất xấu"; the bare split divider "xấu, tôi nghĩ có 1
> line màu fg nhẹ… đẹp và native hơn"; the panel's top bar "nhìn xấu".

- ✅ **Verb 20 `syncCodeFont` — the client's LIVE font truth crosses the wire.** Font prefs are
  client-side (`PreferencesStore.terminal`) and never reached the host (EnvBridge carries no font
  keys), so the seed could only ever guess defaults. Now every ensure round (and every live
  Settings edit) pushes `[family][size][effective line-height ratio]`; the host patches exactly
  the three `editor.font*` keys in the shared settings.json (family first, then the seeded
  fallback stack), churn-free when in sync, never a file creator, JSONC = the user's. The RATIO is
  computed client-side the way the terminal actually renders: CoreText metrics for an installed
  family, the embedded JetBrainsMono 1.32 when the family resolves nowhere (exactly when ghostty
  falls back to that face), × the `adjust-cell-height` multiplier — macbook-pro's 14/loose lands
  as `14` / `1.58`. Host-global last-writer-wins (one shared file — the workspace document's rule
  applied to chrome). The decoder is the validator (family non-blank, size 4…128, ratio 0.5…4;
  NaN fails the range gates). Old host → `unsupportedVerb`, silently kept defaults.
- ✅ **Seed-upgrade stays FONT-BLIND.** A pristine former seed that verb 20 has re-serialized would
  never again be byte-identical — the comparator now canonicalizes both sides (sorted-keys JSON)
  with the three synced keys dropped, so a font-synced seed still upgrades and any OTHER
  divergence stays the user's. The current seed with synced fonts is left alone.
- ✅ **Seed v9 drops `window.density.editorTabHeight`.** Compact = 22px rows; the Slate plate
  recut (height − 8) squeezed those to 14px plates. Stock 35px rows → 27px plates ≈ the app's own
  control height.
- ✅ **The split divider carries the Slate `divider` tint — reversing the bare-ground rule.**
  User-directed: the seam gets "1 line màu fg nhẹ". `flatDividerTone()` now composites the theme's
  `divider` token (fg at its hairline opacity) over `ground` into one opaque colour (the layer bg
  cannot alpha-blend), per-channel plain lerp. The old worry (a raw white/black hairline reads
  heavy against one neighbour) is answered by using the THEME's tint at hairline opacity — the
  same register the pane-grid dividers already draw, so every seam in the window speaks one line.
- ✅ **The panel strip gets a bottom edge in the same language.** A `Slate.Line.divider` hairline
  under the strip closes the ground band against the workbench's tab row — previously two
  mismatched grays stacked with no rule between them. Pixel-proofed: strip hairline, both split
  dividers and the pane-grid line all sample the identical composite tone.
- ⚠️ **Gate trap (cost a full bisect): a SIGNED verify app silently loses the defaults suite.**
  The GUI gates' `SLOPDESK_DEFAULTS_SUITE` mechanism assumes the app is UNSANDBOXED — an
  xcodebuild WITHOUT `CODE_SIGNING_ALLOWED=NO` produces a signed, sandboxed app whose
  suite-named `UserDefaults` resolves in its CONTAINER, where the gate's `defaults write` never
  landed: every fixture key silently reads default (light theme, panel collapsed, fresh-install
  path). Always rebuild gate apps the way `check-macos.sh` does: `CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO`.

## The panel strip becomes a real tab row, and markdown reads rendered (2026-08-03)

- ✅ **The strip speaks otty's tab vocabulary, with a second surface announced.** User-directed:
  the selected tab expands to symbol + text, an unselected tab collapses to its icon —
  `PanelTabPlate` already encodes that grammar; the strip now leads with the selected "Code"
  plate AND the icon-only **Desktop** placeholder beside it — the window-OS surface the 07-22
  pivot promised, a no-op click until that panel exists. Actions (reload, collapse) stay
  trailing. Two same-day follow-ups: the row is CENTERED in the strip band (the titlebar-row
  top-anchor read off-balance), and Desktop's glyph is `display` (the app's existing GUI-surface
  vocabulary; `macwindow` rendered as a blob at strip size).
- ✅ **Seed v11: no git-decoration letter badges on editor tabs.** The sub-baseline "A"/"M" the
  workbench appends to tab labels read as a stray misaligned character (it is the git
  Added/Modified letter, stock workbench behavior, not a theme artifact).
  `workbench.editor.decorations.badges: false` scopes to TABS only — the explorer keeps its
  badges, and the git colour on filenames stays everywhere.
- ✅ **The dark divider tint steps up 0.07 → 0.10.** At 0.07 the fg-tinted seam sat barely above
  the ground tone — more shadow than line. One step brighter keeps it a quiet hairline that
  still reads as light. Light filters stay at 0.08 (their line is black; raising it would darken,
  not brighten). Every seam moves together — the token is the single source.
- ⚠️ **Never quote the user's prompt phrases (Vietnamese or otherwise) in code comments or docs.**
  User-directed 2026-08-03: describe the direction in the file's own language instead.
- ✅ **Seed v10: markdown opens as the RENDERED preview.** `workbench.editorAssociations` maps
  `*.md` to the built-in `vscode.markdown.preview.editor` — in this panel markdown is READ
  (README, docs, agent output), not authored; "Open Source" is one click when needed. v9 moved
  verbatim into `obsoleteSeeds` (10 entries), the font-blind pristine-upgrade carries a
  font-synced v9 forward. Pixel-proofed: README.md boots as a styled preview, no gutter.
- ✅ **Theme polish: the vsix conversion's junk is gone.** Both themes carried five EMPTY-string
  colour values (`diffEditor.move.border`, `diffEditor.moveActive.border`,
  `simpleFindWidget.sashBorder`, `statusBarItem.offlineBackground/Foreground`) — invalid per the
  workbench's colour parser, dropped (defaults are correct). And `settings.checkboxForeground`
  still sat on the chrome ACCENT (yellow dark / pink light) while its twin `checkbox.foreground`
  was already neutral — the one key the neutralization pass missed, now aligned. A test pins
  every colour value to `#rrggbb(aa)` and the two checkbox keys to each other, so conversion junk
  cannot return. Semantic accents (git-modified yellow, error red/pink, lightbulb) stay Monokai.

## The panel tabs go live, and the navigator header becomes a search bar (2026-08-03)

- ✅ **The strip's tabs are REAL — only Desktop's CONTENT is the placeholder.** User-directed:
  `CodeSidebarColumn` grows a `SurfaceTab` selection (`@State`, per-window; survives a
  collapse because the hosting controller keeps the SwiftUI hierarchy, resets to Code on
  relaunch). Selecting Desktop unmounts the pooled webview (warm swap back — the workbench
  returns instantly with its state intact) and shows the placeholder panel; the reload action
  renders only while Code is selected. Pixel-proofed both directions with a live click pass.
- ✅ **The navigator's caps header row is replaced by a full-width SEARCH FIELD.** User-directed,
  two same-day follow-ups: NO trailing hamburger menu (its collapse-all / expand-all / refresh
  actions are gone with it — the chevrons and the git line's own cadence cover them), and the
  field shares the tab cards' exact gutter so both read as one column. The filter reuses the
  pure `RailRowsBuilder` query pipeline the iOS `.searchable` path already exercised; an empty
  result set shows the standard empty label.
- ✅ **The right-panel toggle moves to the terminal section's top-right — and its persistence
  was ALREADY real.** The strip's trailing collapse plate is gone; `SlateTitlebar`'s
  hover-revealed trailing plate now toggles the panel in BOTH states (one location owns
  show/hide). Investigating the "remember open/closed" ask found no defect:
  `WorkspaceChromeState` seeds from `Defaults[.codeSidebarCollapsed]` and both write paths
  persist — proven empirically on the deployed client and pinned headlessly by
  `testCodeSidebarCollapseSeedsFromAndPersistsToDefaults`.
- ✅ **Seed v12: the activity bar folds into the sidebar top — and buys back the web title
  bar.** User-directed after v7's fully-hidden bar left Search / Source Control / Extensions
  reachable by chord only. `workbench.activityBar.location: "top"` FORCE-SHOWS the web
  workbench title bar (re-confirmed on 4.112 — it must host the relocated accounts + manage
  actions; `window.customTitleBarVisibility` stays desktop-only). Accepted: one quiet themed
  band naming the file + project, in exchange for clickable views. CSS-hiding it was rejected —
  the workbench grid positions parts with inline absolute geometry, so `display: none` leaves a
  dead gap rather than reflowing.

## The title bar loses its head, the panel follows the project, the gutter slims (2026-08-03)

- ✅ **The web title bar is CLIPPED off client-side.** User-directed. No seedable key hides it
  while the activity bar sits at "top" (the band must host the relocated accounts/manage
  actions), and CSS `display: none` leaves a dead gap — the workbench grid positions parts with
  inline absolute geometry. The macOS mount (`CodeSidebarWebView`) now lays the webview out
  35px taller than its clipping container and shifts it up by the same: the workbench keeps
  believing in its title bar, the user never sees it. The container bounds-guards `hitTest` —
  without that the overhang sits under the panel's strip and eats its clicks.
- ✅ **A project switch can no longer strand the panel on the OLD project's folder.**
  User-reported: focusing another project's pane left the workbench on the previous project.
  Root cause: the column re-renders BEFORE the switched project's poll task runs, so
  `CodeSidebarModel.phase` still holds the previous `.ready` — and the pool minted the NEW
  root's webview from that stale URL (`?folder=` of the old project), then never corrected it
  (the re-load check compares host/port only, and the shared code-server keeps both constant).
  `.ready` now carries the project root it was ensured for, and the column mounts the webview
  only when that root matches the active one.
- ✅ **Seed v13: the gutter slims.** User-directed ("wasted width"): the panel reads code beside
  a terminal, it does not debug it. `editor.lineNumbersMinChars` 5→3, `editor.glyphMargin` off
  (breakpoints have no meaning here), `editor.folding` off (the arrows column; folding by
  command still works for the rare need). v12 joins `obsoleteSeeds` (13 entries).

## The panel owns its hide toggle, the strip animates as one gesture (2026-08-03)

- ✅ **The right-panel hide toggle moved INTO the panel's strip trailing corner.**
  User-directed. The titlebar over the terminal keeps only the collapsed-state REOPEN
  (hover-revealed, fade-in delayed past the split slide) — the exact split the left sidebar
  already had: hide lives inside the surface it hides, reopen lives in the chrome that
  remains. Both sides now read identically.
- ❌ **Otty's toggle glyphs (`inset.filled.leftthird.square` / `.rightthird.square`) — tried
  and rejected.** Extracted from the otty binary (its `PanelToggleButton` pair, 13pt regular,
  palette two-tone), shipped to pixels, user-rejected on sight as not fitting the app. The
  `sidebar.left` / `sidebar.right` pair stays. Do not re-propose.
- ❌❌ **Two tab-switch animation redesigns — both rejected; the ORIGINAL restored.** Round 1
  (fixedSize label + opacity transitions + surface crossfade on the tab-select token) was
  rejected as cheap-looking fades. Round 2 (pure width morph: label always mounted behind a
  width-0-or-intrinsic frame + clip, reload plate width-clipped, surfaces hard-cut, zero
  opacity anywhere) was rejected as stuttery. The user restored the batch-14 original by name:
  label conditionally in the hierarchy, everything on `smallFade`, surfaces swapping plainly.
  Do not re-propose either redesign; the "jank" both rounds chased reads better to the user
  than either cure.
- ✅ **"Code" → "Files" (`folder` glyph).** User-directed, settled in two steps the same day:
  first a lone `document`, then the folder register from a reference image — the tab opens the
  whole project tree, not one file. Trap recorded on the way: the `doc` family is renamed
  wholesale in SF6, so its new constants need a macOS 15 floor the package (14) does not have
  while the legacy `.doc` deprecation-warns at the app target — if an SF6-only glyph is ever
  required, the raw `SFSymbol(rawValue:)` spelling is the one warning-free path. `folder`
  sidesteps the family entirely.

## The workbench installs from the official VS Code Marketplace (2026-08-03)

code-server ships pointed at Open VSX, whose catalog is opt-in — most first-party `ms-*`
tooling (Pylance, C/C++, …) is simply absent, so the panel's Extensions view could not serve
the extensions a user actually reaches for (user-directed). Every code-server child hostd
spawns — the supervised server and the one-shot CLI — now launches with `EXTENSIONS_GALLERY`
set to the official marketplace URL set (the override code-server itself supports: the env var
is JSON-parsed and replaces the Open VSX default wholesale, so the value mirrors VS Code
stable's `product.json` in full). Consciously NO new flag (important features ship unflagged):
the escape hatch is the env var itself — an operator who exports their own gallery before
hostd keeps it verbatim. No proxy either: the marketplace API answers CORS-open (vscode.dev
consumes it from a browser), so the webview workbench reaches it directly. The ToS trade
(Microsoft scopes the marketplace API to VS Code products) is the operator's own, the same one
every code-server/VSCodium user makes on their personal setup. Proven end-to-end in the GUI
fixture: search finds Pylance, Trust-Publisher + Install lands `ms-python.vscode-pylance` in
the profile's extensions dir, and the language server starts analyzing.

## The workbench theme goes back to stock Monokai Pro (2026-08-03)

Reverses the 2026-08-02 "SlopDesk Monokai" derivation (17 chrome-accent keys neutralized,
Slate plate tab fills, checkbox alignment): the seeded themes are now the STOCK Monokai Pro
pair from the vsix (2.0.13) under their real names — `Monokai Pro` / `Monokai Pro Light` —
with the filter's own accents (dark yellow `#ffd866`, light pink `#e14775`) intact on tabs,
lists and links (user-directed: the stock theme is right as-is). Exactly two departures
survive, both deliberate: the seven structural seam borders (`sideBar`/`panel`/`activityBar`/
`statusBar`(+`noFolder`)/`titleBar`/`editorGroup` `.border`) trade stock's near-black
`#19181a` for the app's Slate `divider` token in alpha form (dark `#fcfcfa1a` = foreground
@ 0.10, light `#00000014` = black @ 0.08), so the workbench's internal seams match the split
dividers around the panel; and the vsix's five empty-string colour values (rejected per-key
by the workbench) are dropped. The vsix's icon themes are deliberately NOT taken — the color
themes only; file icons stay the workbench's stock set. Seed v14 renames the three
`workbench.*ColorTheme` keys and also brings the STATUS BAR back (same user direction:
`workbench.statusBar.visible: false`, hidden since v6, is simply dropped — the workbench
keeps its stock footing, its seam riding the retinted `statusBar.border`); v13 joins
`obsoleteSeeds` so pristine hosts upgrade in place. The extension id/folder
(`slopdesk.slopdesk-monokai-1.0.0`) is unchanged — the drift-repair seeder rewrites the
theme bytes on the next hostd start.

## Every Monokai Pro variant ships, synced from upstream by pin (2026-08-03)

Extends the stock-Monokai-Pro decision above from the two-filter pair to ALL EIGHT variants
the upstream vsix contributes (Monokai Pro + Octagon/Ristretto/Spectrum/Machine filters,
Monokai Pro Light + Filter Sun, Monokai Classic): the workbench's own theme picker (⌘K ⌘T)
now offers the full family, while the seed still boots the classic pair. The vendored
resources stop being a hand-transformed one-off and become REGENERABLE: `scripts/monokai.pin`
records the upstream vsix version, and `scripts/monokai-sync.sh [--latest]` re-downloads,
re-applies the two departures (seam-border retint per dark/light, empty-value drop) and
rewrites `Sources/SlopDeskHost/Resources/` — following upstream is one command + a diff
review, the herdr-sync pattern. The script cross-checks the vsix's contributed theme set
against `CodeServerManager.themeExtensionThemes` (the single source of truth the manifest is
now GENERATED from) and fails loudly on upstream adds/renames. Installing the real
marketplace extension was considered for automatic updates and REJECTED: its activation code
carries the recurring license prompt. The vendored seed takes the theme data only — no code,
no nag (same personal-use posture as before). The extension id/folder stays
`slopdesk.slopdesk-monokai-1.0.0`; the drift-repair seeder rewrites bytes in place and now
also sweeps the two-variant era's differently named theme files.

## Free marketplace extensions install for real; the first one is Material Icon Theme (2026-08-03)

The vendored-data-only rule above exists because the Monokai Pro extension's ACTIVATION CODE
nags for a license — it is not a blanket ban on installing extensions. For fully-free
extensions (no license/purchase prompt anywhere in their activation path) the real install
is strictly better: the workbench's own updater then tracks upstream, nothing is vendored,
nothing needs a sync script. `CodeServerManager.bundledMarketplaceExtensions` lists the ids
the host installs ONCE via `code-server --install-extension` (user-directed 2026-08-03),
checked against the profile registry (`extensions.json` — the installed-set source of truth;
a folder scan lies once the file exists) and run BEFORE the first spawn: ensure answers
`.starting` while the one-shot CLI runs (the client polls ~1 Hz), both so the very first
boot already scans the pack and because install + boot writing the registry concurrently
loses registrations. A failed install (offline host) latches done anyway — the panel is
never held hostage by a nicety; the next hostd launch retries. The first entry is
`pkief.material-icon-theme` (MIT), and seed v15 selects it (`workbench.iconTheme:
"material-icon-theme"`); v14 joins `obsoleteSeeds` so pristine hosts upgrade in place.

## The code panel gets a first-party extension: `slopdesk.slopdesk-bridge` (2026-08-03)

Opening a file in the embedded editor ran `code-server -r <path>`: a fresh Node CLI process
routed through the per-user session socket. Two costs, both measured. It lands in the most
recently registered workbench SESSION, which is not necessarily the window whose folder holds
the file — with two projects open the file could surface in the wrong one. And the session
registers only once some webview has finished booting the workbench, which is why the open
carries a 10 × 2 s retry budget: an 18-second worst case on a cold panel. Even warm the CLI
measured ~160 ms per open (Node boot + IPC), for a command whose payload is one path.

So the host now ships its own extension into the workbench profile, on the same seeding terms
as the Monokai theme (`slopdesk.*` namespace, drift-repaired in place, registered in
`extensions.json` because a folder drop is invisible once that file exists) — except this one
is CODE, not data, which the vendored-theme rule never forbade: it forbade shipping SOMEONE
ELSE's code that nags. `CodeBridgeServer` binds an `AF_UNIX` socket (pid-keyed, 0600, lazily —
a host whose user never opens the panel never creates it), hands the path down through
`childEnvironment` as `SLOPDESK_CODE_BRIDGE_SOCKET`, and every workbench window's extension
host connects back announcing its workspace folder. An open is then one line of NDJSON to the
window whose folder CONTAINS the target, deepest folder first. Verified end to end against a
real code-server 4.112: the extension attached with the right root, and a commanded
`line 3, col 2` open put the caret exactly there.

The CLI arm stays as the fallback and the two are raced on every retry attempt — during a cold
start neither route exists yet, and whichever appears first should win. Nothing changed on the
wire: verb 19's request, response and disposition byte are identical, so an old client and a
new host still agree. The message set is deliberately minimal (hello + open) and versioned by
its own `v` field; this is host-local IPC, not a fourth network path, and it is NOT
golden-pinned.

## The panel's fonts stop riding the injected script (2026-08-03)

The webview's WebContent process cannot see fonts the app registers with `CTFontManager`
(registration is process-scoped), so the panel ships its faces into the page. The first shape
for that was a `data:font/ttf;base64,…` URI per face inside the injected style sheet — which
meant the dressing user script carried 4,069,800 characters of base64 (3,052,348 bytes of TTF
inflated by a third), re-injected and re-parsed on every workbench navigation, once per
pooled webview.

Now the sheet names three short `slopdesk-font://fonts/<face>.ttf` URLs and a
`WKURLSchemeHandler` answers them with the bundle's bytes, memory-mapped. The script drops to
a couple of KB; the faces arrive as ordinary subresources marked `immutable`, so a reload does
not refetch them. A custom scheme rather than http: `setURLSchemeHandler` refuses the standard
schemes, and the fonts are the CLIENT's resources — routing them through the loopback relay in
front of the host's code-server would be wrong on the merits.

Verified with a standalone `WKWebView` probe against a real http origin, reproducing the
cross-origin condition the workbench page creates: the handler served 303,144 bytes and
`document.fonts.check('13px "JetBrains Mono"')` returned true. The negative control was
informative and corrected the comment that shipped first — WebKit loads the face WITHOUT
`Access-Control-Allow-Origin` too, so that header is hygiene against a future tightening, not
the mechanism. It is still sent, and the code says so honestly.

Two riders on the same pass. Verb 20 (`syncCodeFont`) no longer rides every ensure round: an
`.unavailable` host — no code-server binary, polled every ~3.6 s for as long as the panel is
open — was being sent font settings for a workbench that will never boot, and an unchanged
spec was making a round trip whose only possible answer is "nothing changed". `.starting`
still pushes: the seed has to land before the booting workbench reads its settings.

## ⌃` / ⌘` inside the editor reach the terminal PANE (2026-08-03)

The embedded workbench ships VS Code's integrated terminal, and ⌃` opens it. That shell is
outside everything this app exists to provide: no agent detection, no PTY fan-out to the other
clients, no replay buffer, no scrollback journal — a second, worse terminal one muscle-memory
chord away from the good one. Rather than hide it (removing an escape hatch nobody asked to
lose), the chord is spent on the real thing: while the editor holds the keyboard, ⌃` and ⌘`
hand the keyboard back to the terminal pane instead.

They resolve from a PANEL-LOCAL table consulted only inside the webview-yield branch, not from
the chord registry. Keeping them out of the registry is the whole point — the app's at-rest
keyboard is untouched, so AppKit's ⌘` (cycle app windows) and the terminal's own ⌃` keep
working at every other focus, and the cost is paid only where the alternative was worse. ⌘` is
included at the user's direction (2026-08-03); ⌃` is the one VS Code actually binds.

Both spend `.focusCodePanel`, whose hand-back arm fires whenever the webview is the one holding
focus — which inside that branch it always is. The binding is now titled "Switch Editor /
Terminal Focus" in the menu and the palette, which is what it has always done; the id is
unchanged, so no keybinding a user saved moves. ⌘` also came OUT of the webview's reserved-app-
chord list: the NSEvent monitor runs ahead of the whole responder chain, so that case could no
longer run and would have read as a live rule that was not one.

## The editor can type into a real pane — the HOST picks which one (2026-08-03)

The same argument that spent ⌃` on the terminal pane leaves an obvious hole: an editor whose
only way to run the line under the caret is a terminal we just talked the user out of. So the
bridge extension contributes two commands — "Run Selection in SlopDesk Terminal" (editor
context menu) and "Change SlopDesk Terminal Directory Here" (explorer and editor context
menus) — and they type into a genuine SlopDesk pane: agent-detected, fanned out to the other
clients, in the replay buffer, in the scrollback journal.

WHICH pane is decided by the host, not the extension, because focus is a client-side fact the
extension host cannot see and the client that has focus may not even be the one whose editor
issued the command. `CodeBridgeTerminalRouter` is a pure function over the pane set with three
filters, each of which refuses rather than guesses:

* the pane's cwd must be CONTAINED by the workbench root — a command about this project never
  lands in another project's shell;
* no agent may be detected there — typing at Claude Code's prompt does not run a command, it
  sends the agent a message, which is a far worse outcome than doing nothing;
* the foreground process must be a shell — a pane sitting in vim, less or a build is not at a
  prompt, and a stray `npm test\r` there is keystrokes into someone's editor.

Ranking among the survivors is deterministic (most path components shared with the file's
directory, then the deeper cwd, then the lower pane id) so the same gesture keeps landing in
the same pane. Candidates are attached mux sessions only: a detached or agent-spawned control
session is not a terminal the user is looking at. When nothing survives, the extension shows a
warning naming the reason — every project pane busy, or no pane in this project at all.

The `cd` command sends a DIRECTORY, never a command line; the host builds and quotes the `cd`
itself, so shell quoting has one tested home rather than a copy in JavaScript. Requests are
correlated by id and answered either way: the status bar names the pane on success, a warning
the user must dismiss explains a refusal, and a connection that drops takes its pending
requests with it rather than leaving a command that silently never ran.

Verified out of band, in two halves, since neither real sockets nor a real workbench belong in
the unit suite. The socket half ran a probe against the shipping `CodeBridgeServer`: two
windows' hellos, run and cd round trips, the refusal path, malformed/relative/oversized lines
dropped without desyncing the connection, a closed peer not taking the host down. The extension
half drove a real code-server 4.112 under chrome-headless-shell over CDP: both commands appear
in the palette, the selection branch sent exactly the selected characters, the no-selection
branch sent the caret's whole line, the cd carried the resolved directory, and both result arms
(status bar, warning notification) rendered.

## The panel gets a fifth tab: the host's browser, with its own inspector (2026-08-05)

Files, Simulators and Emulators all answer "what is on this machine". Web answers a different
question — "what does this page do" — and it is the one the panel could not answer at all. The
tab drives a browser that runs on the HOST and inspects it with THAT BROWSER'S OWN DevTools
frontend, over Chrome's debugging protocol (`docs/49-web-panel.md`; metadata verb 23).

The obvious build was the cheap one: the client already embeds WebKit, so render the page
locally and open Safari's Web Inspector on it. It was rejected on two counts that a preview
pane cannot buy back. The page under development is served by the HOST — a dev server on the
host's `localhost`, the host's hosts-file, its certificates and its cookies — so a browser
sitting on the host types `localhost:5173` and is there, while a client-side web view needs a
forwarded port for every service and still breaks on the first absolute link the app emits to
its own origin. And WebKit gives an embedding app no supported way to open its inspector at
all: the private route (`_inspector` / `attach`) is what cmux and muxy both use, is macOS-only,
and cmux's own source warns that a repeated attach can crash inside `platformAttach`. A
SlopDesk client also runs on iPad, where that route does not exist.

Chrome serves its entire frontend over HTTP, which turns the whole problem into a URL. Measured
before any of this was written: that frontend renders and drives a page correctly inside
WKWebView on macOS AND on iPadOS 26.5, with no private API on either. One surface, one
behaviour, every client — and nothing of DevTools vendored, so it can never fall out of step
with the protocol behind it.

Two relays, and neither is optional. Chrome binds its debugging port to loopback and cannot be
talked out of it (`--remote-debugging-address=0.0.0.0` is accepted and ignored), so hostd fronts
it. The frontend then opens its websocket back to `ws://127.0.0.1:*` and admits nothing else, so
the client fronts the mesh endpoint on a stable loopback origin of its own — under its own key,
because DevTools stores its whole layout against that origin.

The address bar navigates the EXISTING page over CDP rather than opening a new one: a new target
means a new DevTools session, which is exactly what an address bar must not cost. It is not a
search box either — prose resolves to nothing rather than being shipped to a search engine, and
a bare loopback host gets `http://`, because that is where the host's dev server is.

Unlike the two device tabs, hostd's shutdown terminates this child. A booted simulator or
emulator is the user's own machine state; a headless browser on a private profile is a process
nobody can see to stop.
