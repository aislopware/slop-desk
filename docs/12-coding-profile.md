# 12 — Coding Profile: Hybrid Architecture (terminal text-path + GUI video-path)

> **STATUS: CURRENT** (deep-dive). Front door + decisions: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).
> 4 parts: **A. Hybrid architecture** (§1–7) · **B. Terminal text-streaming — design** · **C. GUI video path** (§1–8) · **D. Roadmap & docs updates**. Output of the research workflow (34 agents, 6 dimensions + verify + gap-fill) for the **daily coding** use-case; **replaces the "every window goes over video" assumption**. Raw corpus: [research/hybrid-research-corpus.json](research/hybrid-research-corpus.json).

> **Framing (shipped build).** Both paths are **shipped and co-equal**. The client is one unified **infinite canvas of panes**; each pane is either a **terminal pane** (host PTY → TCP → libghostty, pixel-perfect text) or a **GUI-window pane** (ScreenCaptureKit → VideoToolbox HEVC → UDP), routed **per pane by content**, not primary/fallback. The "terminal-first, video is the fallback / Phase 4" framing below is preserved as the *original reasoning* for building terminal first — read it as history; the GUI video path has since shipped and is first-class.

## TL;DR — architecture decision

Two **data paths**, surfaced as **co-equal panes on one infinite canvas**, routed per pane by content — both shipped:

| | **Terminal text-path** (like SSH/mosh) | **GUI video-path** |
|--|---|---|
| Used for | shell / vim / tmux / CLI | VS Code, Xcode, browser, other GUI apps |
| Host | spawn login shell in a PTY (`forkpty`), stream the byte stream | ScreenCaptureKit captures 1 window |
| Client render | **libghostty** full surface (Metal GPU — the VVTerm stack), absolutely crisp | VideoToolbox decode → Metal (4:2:0, slightly soft — accepted) |
| Input | **bytes → PTY stdin** | CGEvent/Accessibility inject |
| Idle bandwidth | ~0 | ~0 (skip `.idle`) |

⭐ **Biggest insight:** the terminal path **completely bypasses macOS's input-injection problem** (no CGEvent, no TCC Accessibility, no activate-then-control, no AXUIElement mapping) — input is just bytes written to the PTY. This is why it **was built first**: simpler, crisper, sidesteps the project's biggest risk layer (R1/R2 in [08](08-risks-open-questions.md)). It is also why GUI-window panes are the *only* place input-injection complexity lives.

> Prior-art lesson: VS Code Remote, JetBrains Gateway (dropped Projector pixel-streaming), Blink Shell — **nobody pixel-mirrors the code path**; semantic/text streaming wins. Terminal panes render text via PTY+libghostty rather than video as a content-routing choice, not a verdict that the GUI path is inferior. Pixels stream GUI-window panes (apps with no semantic alternative).

> **Implementation note (current build).** The performance-critical core — both wire codecs (terminal WireMessage + video protocol), FEC + frame reassembly, the realtime controllers (congestion/ABR, FPS governor, LTR, decode gate/sequencer, jitter-depth pacer, delay-gradient trendline, recovery admission), coordinate mapping, and the terminal/PTY protocol incl. the SSH-style channel mux + per-channel flow control — lives in the Rust crate `rust/slopdesk-core` (safe Rust, zero runtime deps, `#![forbid(unsafe_code)]`), exposed over a C-ABI (`rust/slopdesk-ffi`, header `slopdesk_ffi.h`, linked via `CSlopDeskFFI`). The Swift/SwiftUI apps are the platform shell (ScreenCaptureKit capture, VideoToolbox codec, Metal render, input injection, PTY spawn, UI) and call the core through that boundary; the same core backs a future Android client over C-ABI/JNI. Platform floor: macOS 26 / iOS 26 (Apple Silicon). Read "we build X" below as "the shell wires X to the Rust core."

---

## Hybrid architecture: terminal text-path + GUI video-path

> Replaces the "every window goes over video" assumption of [01-architecture.md](01-architecture.md). Two **separate data paths**, routed per window/feature. Use-case: **daily coding** over LAN — most content is terminal/shell text; the GUI editor (VS Code, Xcode) is only one part.

---

### 1. Two paths, one central insight

Every successful remote-coding tool converges: **semantic/text streaming beats pixel streaming for the code path, so the code (shell/TUI) goes through a text path while GUI windows** — where no semantic option exists — **are pixel-streamed.** Content-driven routing, not a ranking. JetBrains abandoned Projector (serializing AWT draw commands over WebSocket) for the thin-client RD protocol because streaming draw commands still has higher latency ("higher UI latency and significantly more network bandwidth"). The best iPad→Mac setup pairs Blink Shell (mosh/SSH) for text with VS Code Server (Remote Tunnels / code-server) for the IDE — **neither side pixel-mirrors** ([JetBrains Gateway blog](https://blog.jetbrains.com/blog/2021/12/03/dive-into-jetbrains-gateway/), [blink.sh](https://blink.sh/), [code.visualstudio.com/docs/remote/vscode-server](https://code.visualstudio.com/docs/remote/vscode-server)).

SlopDesk mirrors that:

| | **TERMINAL text-path** | **GUI video-path** |
|--|------------------------|--------------------|
| Model | app **owns the shell** like ssh/mosh: host spawns a login shell in a PTY, streams the byte stream (VT escape sequences) | mirror 1 GUI window: capture → encode → stream → decode |
| Capture | `forkpty()` / `openpty()` from `<util.h>` (Darwin) | `ScreenCaptureKit` per-window |
| "Encode" | None — raw byte stream over the wire | `VideoToolbox` HEVC 4:2:0 (Media Engine) |
| Client render | **libghostty** full surface (Metal GPU, self-owned patch) | `VTDecompressionSession` → Metal |
| Input | **bytes written straight to PTY stdin** | `CGEventPostToPid` / SkyLight SPI inject |
| Idle bandwidth | ~0 (PTY produces no bytes while idle) | ~0 (`SCFrameStatus.idle` → skip encode) |
| Text quality | **crisp by construction** | 4:2:0 (slightly soft, accepted) |

**Core insight — the single biggest architectural win:** the terminal path **bypasses macOS's input-injection problem**. On the video path, typing a key requires synthesizing a CGEvent and calling `event.postToPid(pid)`, which:

- Requires the **Accessibility** permission (`kTCCServicePostEvent`), granted manually in System Settings, and the **host app must NOT be sandboxed**.
- **Fails silently with Chromium/Electron apps** (VS Code renderer, Chrome, Slack) — the renderer IPC filter rejects synthetic events lacking hardware telemetry. Mouse is rejected more strictly than keyboard; right-click on web content coerces into left-click.
- For canvas/game-engine apps (Blender, Unity) forces **activate-then-control** (raise the window ~1 frame, hand focus back) — breaking the "never steal focus" promise ([trycua: inside-macos-window-internals](https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md)).

The terminal path makes those **disappear**: a keystroke is just bytes written to the PTY master fd over a socket — **no CGEvent, no TCC Accessibility, no activate-then-control, no AXUIElement mapping**. An architectural decision that removes an entire risk layer, technical and distribution-related (Accessibility all but forces distribution outside the Mac App Store).

> ⚠️ **On the "input bypass" (corpus, partially verified):** the bypass is that the **CLIENT never injects into the host OS** — it only sends bytes over the transport; the host writes them into the PTY master fd. A prototype must confirm **no** CGEvent/Accessibility call anywhere in the client key path (libghostty write-callback → `NWConnection`). Easy to verify.

---

### 2. Hybrid architecture diagram

```
┌─────────────────────────────────── HOST (macOS, non-sandboxed) ────────────────────────────────────┐
│                                                                                                    │
│   ╔════════════ TERMINAL PATH (like SSH/mosh) ════════════╗    ╔══════ GUI VIDEO PATH ═══════╗     │
│   ║                                                       ║    ║                             ║     │
│   ║ forkpty()/openpty()  ┌────────────┐                   ║    ║ ┌────────────────┐          ║     │
│   ║ spawn login shell ──▶│ PTY master │                   ║    ║ │ScreenCaptureKit│ 1 window ║     │
│   ║  (-zsh, TERM=        │     fd     │                   ║    ║ │ desktopIndep.  │          ║     │
│   ║  xterm-ghostty,      └─────┬──────┘                   ║    ║ └───────┬────────┘          ║     │
│   ║  LANG=...UTF-8)            │ DispatchIO(.stream)      ║    ║ status==.complete?          ║     │
│   ║                            │ read 128KB               ║    ║         │ (skip .idle)      ║     │
│   ║ ioctl(TIOCSWINSZ)◀── resize│                          ║    ║         ▼                   ║     │
│   ║                            ▼                          ║    ║ ┌──────────────┐ NALU       ║     │
│   ║                     raw VT bytes                      ║    ║ │ VideoToolbox │ HEVC 4:2:0 ║     │
│   ║                            │                          ║    ║ │ HW encode    │ no B-frame ║     │
│   ║                            │                          ║    ║ └──────┬───────┘            ║     │
│   ║                            │                          ║    ║        │                    ║     │
│   ║                            │                          ║    ║ CGEvent/SkyLight inject◀──  ║     │
│   ╚════════════════════════════│══════════════════════════╝    ╚════════│════════════════════╝     │
│         ▲ keystroke bytes      │                                        │                          │
│         │ → PTY stdin          │                                        │                          │
│   ┌─────┴──────────────────────▼────────────────────────────────────────│──────────────────────┐   │
│   │           TRANSPORT  (Network.framework NWListener)                 │                      │   │
│   │ 1-byte msg type (0=PTY data, 1=resize, ...) + 4-byte len + payload  │ video = UDP/QUIC     │   │
│   │ terminal = TCP byte relay (LAN: HOL blocking negligible)            │ (lossy, per [03])    │   │
│   └─────────────────────────────────────────│──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────│──────────────────────────────────────────────────────┘
                                              │  LAN (<1ms RTT)
┌────────────────────────────────── CLIENT (macOS / iOS / iPadOS) ───────────────────────────────────┐
│   ┌─────────────────────────────────────────▼──────────────────────────────────────────────────┐   │
│   │                        TRANSPORT (NWConnection) + demux by msg type                        │   │
│   └──────────┬─────────────────────────────────────────────────────────┬───────────────────────┘   │
│              │ raw VT bytes                                            │ NALU                      │
│              ▼                                                         ▼                           │
│   ┌────────────────────────┐                                 ┌──────────────────┐                  │
│   │ libghostty surface     │ feed_data()                     │ VTDecompression  │                  │
│   │  emulator (Metal)      │                                 │  → Metal render  │                  │
│   │  TerminalViewDelegate  │ ── send(source:data:) ──┐       └──────────────────┘                  │
│   └──────────┬─────────────┘  keystroke → bytes      │                                             │
│              ▲                                       └──▶ straight to PTY stdin (NOT injected)     │
│              │ hardware/soft keyboard                                                              │
│   ┌──────────┴────────────┐                             ┌───────────────────┐                      │
│   │ Input (UIKey/NSEvent) │                             │ Mouse/touch input │──▶ inject into host  │
│   └───────────────────────┘                             └───────────────────┘ (video path only)    │
│                                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### 3. Detailed data flow for each path

### 3.1 TERMINAL text-path (the PTY text-path)

**Host PTY → byte stream → libghostty.** Host spawns a login shell in a PTY, reads the master fd (DispatchIO), streams raw VT bytes; keystrokes written straight to PTY stdin; resize via `TIOCSWINSZ`+SIGWINCH. **Full API details** (forkpty vs `openpty`+`posix_spawn`, DispatchIO, env vars + IUTF8, corpus corrections) are in **Part B §1** — single source, not repeated here.

**Client renderer — libghostty (full surface) + SELF-OWNED external-backend patch. [DECISION FINAL]**
Use **libghostty** (the Ghostty engine) for macOS + iOS — Ghostty-class rendering (Metal GPU, highest VT fidelity, Kitty graphics, ligatures). This is the stack VVTerm + Moshi/Echo/RootShell run in production on iOS, a 1:1 match (the client has no local PTY; it renders a byte stream from the network).

> 🔑 **Integration (settled): SELF-OWN a minimal external-backend patch — do NOT depend on a fork.** Research recommended SwiftTerm-engine+own-renderer (mature), BUT we prioritize **Ghostty-class rendering**, so keep full libghostty and **own a small patch**. Why "depend on a fork" was rejected: both external-IO forks are **proven in shipping apps** ([17 §2.2] — VVTerm on `wiedymi/ghostty:custom-io`, Geistty on `daiimus/ghostty:ios-external-backend`) but both are **bus-factor 1**; `wiedymi:custom-io` lacks a resize callback, `daiimus` has **External.zig + resize callback + tests** (→ the better reference). Owning the patch (ref daiimus) = we control rebases.

**Data path (per VVTerm, source-confirmed):** network bytes (plain TCP over the trusted mesh) → `ghostty_surface_feed_data()` → Ghostty's VT parse + Metal render; keystrokes out via `ghostty_surface_set_write_callback` (`use_custom_io = true`) → write to `NWConnection` → PTY stdin on the host. Resize via the surface API → host `ioctl(TIOCSWINSZ)`.

> ✅ **Decision (FLIPPED SwiftTerm → libghostty, verified 2026).** All three old objections collapsed:
> - **iOS proven in production** — VVTerm (`vivy-company/vvterm`, source read: `ghostty_surface_new` on `GHOSTTY_PLATFORM_IOS`, **full surface**), Moshi (getmoshi.app, Ghostty 1.3.1), Echo, RootShell (`kitknox/rootshell`). Mitchell Hashimoto endorses.
> - **full libghostty CAN be fed network bytes** — via the external/custom-io backend. The "assumes it owns the PTY" objection is only true of upstream main.
> - **no tagged release yet** — still true (Ghostty 1.3.1) but does NOT block production.
> - **Use the FULL surface, NOT vt + own renderer** (take Ghostty's Metal renderer as-is; vt+own-renderer is the unfinished road Spectty is on).
>
> **Self-owned patch recipe (references, NOT dependencies):**
> 1. **External-backend patch (self-maintained)** — feeding external bytes is patch-only (upstream `ghostty-org/ghostty` only spawns PTYs; iOS cannot spawn processes → in-process patch MANDATORY). Reference: **`daiimus/ghostty ios-external-backend`** (`External.zig` ~470 LOC — resize callback + unit tests + ARCHITECTURE.md) over `wiedymi/ghostty custom-io` (~a dozen lines, no resize, frozen). API: `use_custom_io` / `GHOSTTY_BACKEND_EXTERNAL` + `ghostty_surface_set_write_callback` + `ghostty_surface_feed_data`. Delta ~hundreds of LOC → ownable + rebasable.
> 2. **Swift wrapper (self-written, ref Lakr233):** `Lakr233/libghostty-spm` has `InMemoryTerminalSession` (`write: (Data)->Void` + `receive(_ data: Data)` + UIKit input/IME/accessory/Metal display link) — maps exactly to our use-case → reference for our wrapper, not a dependency.
> 3. **Build from Zig (self-hosted, ref Lakr233 `build.yml`):** `zig build -Demit-xcframework=true` (Zig 0.14+, Xcode 15+) → slices ios-arm64 / ios-arm64-sim / macos → vendor `GhosttyKit.xcframework`, **pin the upstream Ghostty commit SHA**, re-apply the patch on bumps. A build-time lock, not a runtime risk.
> 4. **Wrap behind a `TerminalRendering` protocol** (`feed(bytes)` + `onOutboundBytes`) to isolate the C-ABI binding.
>
> **The accepted price:** we dodge the **bus factor** (we own the patch) but still carry the **ABI-instability tax** — the libghostty C-ABI has no stable release (`vt.h`/`ghostty.h`: "not a general purpose embedding API yet"), so every Ghostty bump means **rebase the patch + verify the ABI** + maintain our own **Zig toolchain**. Effort: small patch + pipeline ~**1–3 engineer-weeks** up front, then hours per rebase.
>
> ✅ **Open questions RESOLVED (source read — `research/resolve-open-questions-corpus.json`):**
> - (a) **Alt-screen (1049/smcup/rmcup) works CORRECTLY** through the external backend — all 3 feed functions land in the same Ghostty VT parser (`processOutput → terminal_stream.nextSlice`). → **fullscreen Claude Code OK.**
> - (b) **The external-backend API is OPAQUE** — does NOT expose the parsed escape-stream / cell grid / cursor (`ghostty.h` has only `read_text`/`read_selection` snapshots + **action callbacks**: `COMMAND_FINISHED`+exit_code+duration, `PWD`, `SET_TITLE`, `PROGRESS_REPORT`, `CELL_SIZE`). → **Build block/status UI on action callbacks**, do NOT parse raw OSC client-side. (Separate `libghostty-vt` has a grid API but doesn't bridge to `ghostty_surface_t`.)
> - (c) **Keyboard: Ghostty encodes keys itself** via `ghostty_surface_key()` (reads live kitty_flags/DECCKM) → **route EVERY key through it**; ⚠️ **do NOT use Lakr233's bypass** (`TerminalHardwareKeyRouter` hardcodes protocol-blind VT100 for nav keys when inMemory+no-modifier — wrong for a remote PTY in kitty/DECCKM mode).
> - (d) **TCP needs only simple buffering** — in-order lossless; an escape sequence may split across 2 reads → the stateful VT parser holds state across reads (no seq/ACK/dedup/reorder needed).
> - (g) **Thread-safety: feed from a dedicated I/O thread, serialized per surface** (`processOutput` acquires `renderer_state.mutex`; concurrent feeds safe across DIFFERENT surfaces, NOT the same surface). VVTerm's `@MainActor` is convention, not requirement.
> - **Lakr233's `InMemoryTerminalSession`** = a wrapper over patch `0002-host-managed-io.patch` (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` + `write_buffer` + `process_exit`) → **reference for our patch** (alongside daiimus External.zig).
>
> 🔬 **ONLY A SPIKE can answer (measure on device):** (e) binary size of the XCFramework Metal renderer on iOS; (f) shell-integration OSC 133 e2e over the network. Codec spikes at [§5/§6](#5-videotoolbox-configuration-for-static-screens) + the Phase 0 checklist.

> ⚠️ **Threading with libghostty (verify on device):** confirm which queue calls `ghostty_surface_feed_data` from the network receive loop (Ghostty manages its own render thread + Metal/IOSurface). *The SwiftTerm `feed()` data-race caveat NO LONGER applies* (we switched to libghostty).

**Scrollback:** a raw PTY has no scrollback. Simplest is **client-side**: the libghostty surface keeps a ring buffer of lines → the server stays a **stateless byte relay**, zero cost. For replay-on-reconnect, keep a server-side ring buffer of raw bytes (~1MB) — far simpler than mosh-style state sync.

### 3.2 GUI video-path (for GUI-window panes)

Path for **GUI-window panes** (VS Code/Xcode/browser...), co-equal with the terminal path, routed by content. **Details** (per-window capture, idle-skip `SCFrameStatus.idle`, dirtyRects, HEVC 4:2:0 constant-quality encode + caveats) in **Part C** below + [02](02-host-capture-encode.md)/[09](09-codec-choice.md). Input injection (CGEvent/SkyLight — **this path only**) in [05](05-input-window-control.md).

---

### 4. Per-pane routing: terminal for shells/TUIs, GUI video for GUI windows

**Routing rule: pick the path by pane content** — terminal panes for shells/TUIs, GUI-window panes for GUI apps; both first-class, both ship. Corpus reasons the split is content-driven (not a ranking):

- **Market share & workflow.** VS Code holds 75.9% IDE share but Vim/Neovim combined are ~38% usage (Stack Overflow 2025); terminal-centric workflows (Neovim + tmux, CLI, git, build systems) **account for most daily coding** on a remote Mac. The terminal path serves this bloc directly — why it was built first.
- **Each path fits its content:** terminal sidesteps input-injection, near-zero bandwidth, text crisp by construction, clean APIs (`apple_support: native`, `difficulty: low`); GUI video is the only way to surface a GUI app where no semantic protocol exists.
- **The video path carries more machinery:** CGEvent/SkyLight injection, private SPIs, distribution risk, 4:2:0 softness — all isolated to GUI-window panes.

**Bring-up history (now both shipped):**

1. **Terminal panes shipped first.** Low risk, clean APIs, tiny bandwidth. One `NWConnection` TCP byte relay + 1-byte-type framing.
2. **GUI-window panes then shipped as co-equal**, started on demand via a window picker (`SCShareableContent` list — the safest & most explicit approach). CGEvent limitations accepted within GUI-window panes; non-GUI content stays on the terminal path.

**Activating a GUI-window pane:** a window picker is safest & clearest; avoid auto-detecting windows — classifying "terminal or GUI editor" has no reliable API. The **terminal embedded in a GUI** case (VS Code integrated terminal, Xcode console) is open — don't split it out; leave it inside that window's GUI-window pane.

---

### 5. Wire protocol for the terminal path

No mosh SSP (state-diff UDP) on a LAN. With LAN RTT <1ms and loss <0.01%, TCP head-of-line blocking is **negligible** — raw byte streaming over TCP delivers equivalent performance for far less effort. (Mosh optimizes for lossy WAN; its SEND_INTERVAL_MIN=20ms caps server→client at 50fps, meaningless on a LAN.)

**Framing (ttyd-style, clean for multiplexing resize):**

```
1-byte msg type  (0 = PTY data, 1 = resize, ...)
4-byte big-endian payload length
payload bytes (raw PTY data / {cols,rows} for resize)
```

`NWConnection(.tcp)` over Network.framework: `NWListener` on host, `NWConnection` on client; manual 4-byte length framing or `NWProtocolFramer`. **No app-layer TLS** — the trusted mesh encrypts ([13]). Framing + mux + flow-control run in the Rust core's terminal namespace behind the C-ABI. The PTY master fd produces no bytes while the shell is idle → no bytes flow.

> **Local echo / prediction — NOT needed on LAN (confirmed).** Mosh's Adaptive-mode predictor is **dormant** when SRTT < ~60ms: `srtt_trigger` only turns on when `send_interval > 30ms`, and on LAN `send_interval` clamps to the 20ms floor. Instant echo would require `DisplayPreference = Always` (verified from `terminaloverlay.cc:434` + `transportsender.h:49`). With a PTY-over-LAN round-trip of 1–5ms, server echo arrives before the user notices → **drop prediction for v1**. The engine is transport-agnostic (nosshtradamus runs it over SSH/TCP), so it can be added later if Wi-Fi needs it.

---

### 6. App Sandbox — a hard architectural constraint

**The host component must NOT be sandboxed** — a sandboxed app cannot `forkpty()`/`execvp()` an arbitrary login shell (no entitlement whitelists one). Route: a **non-sandboxed Developer ID app** (like Xcode, VS Code, iTerm2, Terminal.app), or a non-sandboxed LaunchAgent/XPC helper behind a sandboxed app. The video path already needs non-sandboxed for Accessibility/CGEvent (see [06](06-permissions-distribution.md)), so "host = non-sandboxed Developer ID app" unifies both paths; the client viewer (render + send bytes) **can** ship on the Mac App Store. Full detail: Part B §1.5.

---

### 7. Summary & work for the roadmap

| Criterion | Terminal path | Video path |
|----------|---------------|------------|
| Input-injection problem | **Disappears entirely** | Remains in full (CGEvent + SkyLight SPI) |
| TCC permission | None needed (network only) | Accessibility + Screen Recording |
| Sandbox | Must be non-sandboxed (spawns a shell) | Must be non-sandboxed (Accessibility) |
| Idle bandwidth | ~0 | ~0 (when guarding `.complete`) |
| Text sharpness | Absolutely crisp | 4:2:0 slightly soft (accepted) |
| Difficulty / risk | low / native | medium / private SPI |
| Key library | **libghostty** (full surface, self-owned patch) + host PTY bridge | ScreenCaptureKit + VideoToolbox |

**Work that shipped the terminal panes (built first):**
- [x] Non-sandboxed host helper: `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()`, env setup (`TERM`/`LANG`/`IUTF8`), `DispatchIO` read loop, `TIOCSWINSZ` resize.
- [x] Wire protocol: 1-byte type + 4-byte length over `NWConnection` TCP; separate resize message.
- [x] Client: **libghostty** full surface — **self-maintained external-backend patch** (ref `daiimus/ghostty` External.zig), build `GhosttyKit.xcframework` (zig), vendor + pin upstream SHA; `ghostty_surface_feed_data` ← network, write-callback → host PTY stdin, resize → surface API.
- [x] Confirm via prototype: **no** CGEvent/Accessibility call anywhere in the client key path.
- [x] (now shipped, co-equal) Window picker to open a GUI-window pane on demand.

---

## Terminal text-streaming (SSH/mosh-class) — design

The **terminal half** of the hybrid architecture — co-equal, routed for different content. Unlike the GUI window path (ScreenCaptureKit → HEVC → CGEvent inject), the terminal path **owns the shell** like `ssh`/`mosh`: host spawns a login shell in a POSIX pseudo-terminal, streams the **raw byte stream** (VT escape sequences), keystrokes written **straight to PTY stdin**. Consequence: **entirely sidesteps macOS's CGEvent/Accessibility injection limits** — no synthetic keyboard events, no TCC `kTCCServicePostEvent`, no activate-then-control. Text crisp by construction, bandwidth tiny (idle = 0 bytes), no codec artifacts.

---

### 1. Host PTY bridge — exact APIs

#### 1.1 PTY allocation: `forkpty()` vs `openpty()` + `posix_spawn`

Two routes, both native Darwin (`<util.h>`):

**`forkpty()` — one-call PTY + fork + exec.** `forkpty(&master, NULL, NULL, &winsize)` atomically allocates the PTY pair, `fork()`s, calls `login_tty()` in the child, returns the master FD in the parent; the child `execvp()`s the login shell. SwiftTerm's production path (`Pty.swift` → `PseudoTerminalHelpers.fork(andExec:)`) — the master FD is the single bidirectional I/O channel ([SwiftTerm/Pty.swift](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Pty.swift)).

> ⚠️ **CORRECTION — "forkpty() is unsafe from Swift" is overstated (verified):** Quinn (Apple DTS, [thread/747499](https://developer.apple.com/forums/thread/747499)): the real danger is running Swift/ObjC/libdispatch code **in the child after fork() and before exec()** — the ObjC runtime crash guard (`objc_initializeAfterForkError`, since macOS 10.13) kills the child if a `+initialize` was running on another thread at fork time. **The `forkpty()` call itself, in the parent, is NOT dangerous.** SwiftTerm calls it directly in production (Secure Shellfish, La Terminal, CodeEdit) by following fork-then-exec-immediately: prepare every C string with `strdup()` **before** the fork, then in the child only `chdir()` + `execve()` + `_exit()` — pure POSIX, no Swift runtime after fork. Unrelated to Swift 5.9/6 concurrency; no new API relaxes it. To eliminate the hazard class, use the second route.

**`openpty()` + `posix_spawn` — Apple's recommended workaround.** `openpty(&master, &slave, NULL, &termp, &winp)` allocates the PTY pair **without forking**; launch the child via `posix_spawn` with a `posix_spawn_file_actions_t` redirecting stdin/stdout/stderr to the slave FD, `POSIX_SPAWN_SETSID` creating a new session, and `login_tty(slave)` in a pre-spawn configurator. **Never calls fork() from Swift**, eliminating the ObjC runtime lock hazard — exactly what LLVM sanitizer_common does ([D65253](https://reviews.llvm.org/D65253)) and where SwiftTerm is migrating via `swift-subprocess`.

> ✅ **VERIFIED — `POSIX_SPAWN_SETSID` via `preSpawnProcessConfigurator` is a real production API** in `swiftlang/swift-subprocess` (canonical repo `swiftlang/`, **not** `apple/`). `PlatformOptions.preSpawnProcessConfigurator` is `public`, unguarded, with a live test (`testSubprocessPlatformOptionsProcessConfiguratorUpdateSpawnAttr`). In **current SwiftTerm** the Subprocess path is guarded `#if false //canImport(Subprocess)` (5 places in `LocalProcess.swift`) → not active yet; default is still `startProcessWithForkpty`.

> ✅ **VERIFIED — `posix_openpt()` is NOT "broken" on macOS** (claim refuted). Original claim misattributed the thread (actually [thread/734230](https://developer.apple.com/forums/thread/734230), not 688534). Truth: `posix_openpt()` works fully on macOS 14/15; Apple's `openpty()` **calls it internally** (Libc `util/pty.c:78`). The real limitation is narrow: `fcntl(masterFd, F_SETFL, O_NONBLOCK)` fails with `EINVAL` **if the slave has not been opened yet** — fix: open the slave before setting non-blocking on the master. `openpty()` avoids it by opening the slave itself.

#### 1.2 Async reads on the master FD: `DispatchIO`

Wrap the master FD in `DispatchIO(type: .stream, fileDescriptor: masterFd)`:

```swift
let io = DispatchIO(type: .stream, fileDescriptor: masterFd, queue: readQueue) { err in
    close(masterFd)              // ⚠️ close in the cleanupHandler, NOT in deinit (avoids the EV_VANISHED crash)
}
io.setLimit(lowWater: 1)
io.setLimit(highWater: 131_072)  // 128 KB — absorbs large bursts (cat of a big file)
// chain reads in the completion handler; coalesce on a 4ms timeslice before dispatching to the transport
```

SwiftTerm uses a `pendingChunks` queue with a **4ms timeslice** (`pendingTimeSliceNs = 4_000_000`) to coalesce bursts, `readSize = 128*1024`, compacting past `pendingChunkFlushThreshold = 32` chunks. Track shell exit without polling via `DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit)` then `waitpid(shellPid, &n, WNOHANG)` ([SwiftTerm/LocalProcess.swift](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/LocalProcess.swift)).

#### 1.3 Resize: `TIOCSWINSZ` + `SIGWINCH`

On a new client size, call `ioctl(masterFd, TIOCSWINSZ, &winsize)`; the kernel sends `SIGWINCH` to the foreground process group, and the shell + vim/tmux re-query `TIOCGWINSZ` and reflow. Struct `winsize { ws_col, ws_row, ws_xpixel=0, ws_ypixel=0 }`. On macOS `TIOCSWINSZ` is typed `Int32` (Linux needs a `UInt` cast). What SwiftTerm's `setWinSize()` and mosh-server do on a `Resize` action ([SwiftTerm/Pty.swift:119](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Pty.swift), [mosh-server.cc](https://github.com/mobile-shell/mosh/blob/master/src/frontend/mosh-server.cc)). Bandwidth ~0.

#### 1.4 Login shell setup — required env vars

Set before `execvp` in the child:

| Variable | Value | Reason |
|------|---------|-------|
| `TERM` | `xterm-ghostty` (fallback `xterm-256color` if paste bug #54700 shows up — see [14]) | matches the libghostty client + kitty keyboard |
| `LANG` | `en_US.UTF-8` | **critical** — without it vi/ncurses emit ISO 2022 sequences |
| `COLORTERM` | `truecolor` | true-color terminal |
| `NCURSES_NO_UTF8_ACS` | `1` | forces ncurses to UTF-8 box-drawing instead of VT100 line-drawing |
| termios `c_iflag` | `\|= IUTF8` | correct backspace-over-multibyte |
| `argv[0]` | prepend `-` (e.g. `-zsh`) | login shell → sources `.zprofile`/`.zshrc` |

Do **NOT** blindly forward `PATH`. Mirror `LOGNAME/USER/HOME/DISPLAY` from the parent. Reference: `SwiftTerm.Terminal.getEnvironmentVariables()`; mosh additionally does `unset STY` (so GNU screen doesn't think it is nested).

> ✅ **VERIFIED — `IUTF8` exists on Darwin.** XNU `bsd/sys/termios.h:133` defines `IUTF8 = 0x00004000` under `#if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)` → present in any non-strict-POSIX build. It only affects **canonical-mode VERASE**; in raw PTY mode it has no effect — set it anyway for correctness.

#### 1.5 App Sandbox — an architecture decision, not a runtime one

A sandboxed app **cannot** `forkpty()`/`execvp()` an arbitrary shell — the sandbox blocks exec of processes not declared in entitlements, and **no entitlement** whitelists an arbitrary shell. Apple-accepted patterns:

1. **A non-sandboxed app via Developer ID** (outside the Mac App Store) — standard for dev tools (Xcode, VS Code, iTerm2, Terminal.app are all **not** sandboxed). **Recommended for the host.**
2. A non-sandboxed LaunchDaemon/LaunchAgent helper, talking to the sandboxed app over XPC or a local socket.
3. A privileged helper via `SMJobBless`/`SMAppService`.

**The host must be non-sandboxed**; Mac App Store distribution is **incompatible** with arbitrary shell spawning via `forkpty`. Enable **Hardened Runtime** (`codesign -o runtime`) to block dylib injection (`DYLD_INSERT_LIBRARIES`); the PTY-spawning helper needs **no** special entitlement — but must **not** add `com.apple.security.cs.disable-library-validation`. Run the shell **as the logged-in user, not root**; pin the shell binary (`$SHELL` from `/etc/passwd`), and **never let the client specify** path/env (lesson from ET CVE GHSA-hxg8-4r3q-p9rv: client-supplied path reaching a privileged file op → escalation).

---

### 2. Transport — choose reliable TCP, not mosh-SSP UDP

Key decision, corpus unambiguous: **on LAN, use a plain TCP byte relay over Network.framework. Do NOT port mosh SSP.**

| | TCP byte relay (ET-style) | mosh SSP (UDP state-sync) |
|--|---------------------------|---------------------------|
| Unit | raw PTY bytes verbatim | terminal **state diff** (framebuffer) |
| Loss tolerance | TCP handles it (LAN loss ~0) | idempotent datagrams, tolerates loss |
| Crypto | TLS 1.3 (CryptoKit/Security) ready-made | **AES-128-OCB3** |
| Server emulator | **not needed** (stateless relay) | **must run a full emulator** (`Terminal::Complete`) |
| Code | minimal | complex (state machine, fragmentation, fec) |
| Fit | **LAN <1ms RTT** | lossy WAN |

Decisive reason: on LAN, RTT **<1ms**, loss <0.01% → TCP head-of-line blocking is **insignificant**, mosh-style frame-skipping **buys nothing** over raw TCP while complexity is far higher. Mosh SSP targets a 29% packet-loss link (SSH 16.8s → SSP 0.33s, 50× — [mosh paper](https://mosh.org/mosh-paper.pdf)) — a situation that **does not exist** on wired LAN.

> ⚠️ **CORRECTION — AES-128-OCB is not in CryptoKit** (verified). If you ever wanted to port SSP: CryptoKit exposes **only** `AES.GCM` and `ChaChaPoly`, **no** `AES.OCB`; CommonCrypto has no `kCCModeOCB` either. Three options: (1) port mosh's `ocb_internal.cc` using CommonCrypto as the raw AES block backend (how mosh builds on macOS), (2) link OpenSSL and use `EVP_aes_128_ocb()`, or (3) replace OCB with AES-GCM + CryptoKit (wire format differs from mosh). Since we do **not** use SSP, this is only a warning — use native **TLS 1.3 / AES-GCM** over TCP.

#### Wire protocol — type-prefix framing (ttyd-style)

Simplest for LAN, resize rides alongside data:

```
[1-byte type] [4-byte big-endian length] [raw payload]
  type 0 = terminal data (raw PTY bytes verbatim)
  type 1 = resize {cols, rows}
```

ttyd uses exactly this: server→client `'0'`=OUTPUT, client→server `'0'`=INPUT, `'1'`=RESIZE ([ttyd/protocol.c](https://github.com/tsl0922/ttyd/blob/main/src/protocol.c)). **No JSON on the hot path.** Transport `NWConnection(.tcp)`: `NWListener` on host, `NWConnection` on client; manual 4-byte framing or `NWProtocolFramer`. The framing, an **SSH-style channel mux + per-channel flow-control window** (RFC 4254's `window-change` payload — cols/rows uint32 — carries resize), and the dual data/control channels run in the Rust core's terminal namespace behind the C-ABI ([RFC 4254](https://datatracker.ietf.org/doc/html/rfc4254)).

> 📋 **Verify during implementation:** `NWProtocolFramer` handles arbitrary byte sequences (not treated as text) and has no min-MTU constraint fragmenting small keystrokes.

Idle efficiency: the master FD **produces no bytes while the shell is idle** → 0 bytes flow, no encode/decode. The most important perf lever for a coding tool (the screen is static most of the time).

---

### 3. Mosh-style predictive local echo — ⏸️ DEFERRED (assume P2P)

> ⏸️ **DEFERRED for v1** (assume direct P2P over the trusted mesh ~1–5ms, drop prediction — see [13 §4], Phase 5). Kept as **reference** if relays become common.
>
> 🔎 **Update (see [17 §2.4]):** more reasons *not* to build a full predictor than low RTT: (1) `ghostty_surface_t` is opaque → forces a **second VT parser** with a shadow framebuffer (desync risk); (2) **the Claude Code TUI uses the alt-screen** → Mosh disables prediction there anyway, so benefit shrinks to the bare shell prompt. Cheap Phase 2 substitute = a **glitch-window caret** (track only the cursor column, no shadow parser).

The most port-worthy mosh technique, **independent of transport**. Predicts the result of a keystroke and renders it **instantly** (before the packet leaves the NIC), `underline`s unconfirmed characters, self-corrects when real server state arrives. USENIX ATC 2012 (40h / 9,986 keystrokes): **70% of keystrokes displayed instantly**, only **0.9%** needed within-RTT correction.

#### The engine is portable logic, not OS-dependent

> ✅ **VERIFIED — PredictionEngine fully transport-agnostic.** `terminaloverlay.cc` includes no `Network::` class. It needs only **4 values** via plain setters: `local_frame_sent`, `local_frame_acked`, `local_frame_late_acked` (echo_ack from remote state), `send_interval` (= `ceil(SRTT/2)` clamped `[20,250]`ms). nosshtradamus proved the engine runs over **TCP/SSH** using a side-band ping to reconstruct those 4. So over our TCP byte stream, just maintain an epoch counter + RTT estimate → the engine runs unmodified.

Core mechanics (`terminaloverlay.h/.cc`):
- **`new_user_byte(byte)`**: printable ASCII (0x20–0x7e, width 1) → advance predicted cursor, store a `ConditionalOverlayCell` at `(row,col)`, tagged with current `prediction_epoch`.
- **`apply(server_fb)`**: layer the overlay onto the server framebuffer before the display diff.
- **Backspace (0x7f)**: decrement cursor.col, shift the line left (each cell = the cell to its right), rightmost cell `unknown=true` (renders underlined).
- **Epoch self-correction**: when server-confirmed state differs from prediction, `kill_epoch(tentative_until_epoch)` discards every tentative prediction of that epoch; `become_tentative()` increments `prediction_epoch`. A misprediction only kills the current epoch; older confirmed predictions stay. **Control chars (arrows, Escape) also call `become_tentative()`** (unpredictable).
- **Paste suppression**: if `bytes_read > 100` (bulk paste) → `reset()` all predictions (avoids flicker while readline re-wraps).

#### ⚠️ The decisive CORRECTION for LAN: use `DisplayPreference = Always`

> ✅ **VERIFIED — On LAN, Adaptive mode yields ZERO local echo.** In `cull()`, `srtt_trigger` flips `true` only when `send_interval > SRTT_TRIGGER_HIGH=30ms` (strict). And `send_interval = max(ceil(SRTT/2), 20)` → for **any SRTT < ~40ms**, `send_interval = 20ms`, not > 30 → trigger silent. With `display_preference == Adaptive`, `apply()` renders when `srtt_trigger || glitch_trigger`; both false → **renders nothing**. The trigger only fires at SRTT ≥ ~61ms. **On direct LAN (1–5ms) prediction is nearly useless → DEFER.** If relays become common, enable with `DisplayPreference=Always`.

Reference constants (verified): `SRTT_TRIGGER_HIGH=30`, `SRTT_TRIGGER_LOW=20`, `FLAG_TRIGGER_HIGH=80`, `FLAG_TRIGGER_LOW=50`, `GLITCH_THRESHOLD=250ms`, `GLITCH_FLAG_THRESHOLD=5000ms`, `SEND_MINDELAY=8ms` (client sets `set_send_delay(1)`=1ms), `SEND_INTERVAL_MIN=20ms`, paste suppression `>100` bytes.

#### Two implementation options

`terminaloverlay.cc` is ~750 lines of C++. (a) **CGo/C interop** (as nosshtradamus does with go-mosh) — reuse battle-tested code; (b) **a pure Swift port** — cleaner, avoids the C bridge (no existing Swift port → real work). Because libghostty is opaque (no cell-grid access), the full engine needs its own client-side shadow VT parser — exactly why we do **not** build it for v1 ([17 §2.4]). If Phase 2 needs it, this is the integration point.

---

### 4. Client renderer — libghostty

Renderer = **libghostty full surface**; decision + external-backend patch recipe in §3.1 "Client renderer — libghostty". Wiring: `ghostty_surface_feed_data` ← network bytes; write-callback (`use_custom_io`) → PTY stdin; wrap behind a `TerminalRendering` protocol to isolate the C-ABI. (SwiftTerm `Pty.swift`/`LocalProcess.swift` remain only a *citation* for the POSIX PTY pattern in Part B §1, not a dependency.)

### 5. Resize / encoding / scrollback

- **Resize**: client `sizeChanged` delegate → message type 1 → host `ioctl(masterFd, TIOCSWINSZ, &winsize)` → `SIGWINCH` (§1.3). Zero bandwidth.
- **Encoding**: UTF-8 end-to-end. `LANG=en_US.UTF-8` + `IUTF8` + `NCURSES_NO_UTF8_ACS=1` (§1.4). libghostty handles grapheme clusters/emoji on the client.
- **Scrollback**: **client-side only**. A raw PTY has **no scrollback** — bytes once read are gone from the OS buffer. The libghostty surface keeps scrollback internally (via the surface config). **The server is a stateless byte relay** → zero cost. Optional: server keeps an **ET-style seq replay buffer** (§6, [17 §2.3]) for reconnect.

---

### 6. Reconnect / roaming

#### ET-style packet-framed buffering — the right way

Eternal Terminal's `BackedWriter`/`BackedReader` is the direct prior art: buffer **complete packets** tagged with a `sequenceNumber` (deque, capped at `MAX_BACKUP_BYTES = 64MB`). Reconnect: client sends its reader `sequenceNumber` in a `SequenceHeader` protobuf → server's `recover(lastValidSeq)` computes how many packets to retransmit → packs a `CatchupBuffer` → both sides `revive(newFd)`. **The unit is a complete packet, not a raw byte slice** → replay always starts on a packet boundary, **structurally eliminating mid-escape-sequence truncation** ([BackedWriter.cpp](https://github.com/MisterTea/EternalTerminal/blob/master/src/base/BackedWriter.cpp), [Connection.cpp:96-141](https://github.com/MisterTea/EternalTerminal/blob/master/src/base/Connection.cpp)). Overhead: ~1 RTT for the sequence exchange.

> ⚠️ **Data-loss boundary:** ET `DISCONNECT_BUFFER_BYTES = 4MB` — while disconnected, once the buffer exceeds 4MB, `write()` returns `SKIPPED` (new output dropped). For long builds running while the client is offline, output can be lost. Consider raising the disconnect buffer (bounded by RAM) for coding.

#### Fallback raw-byte path: DECSTR prefix

> Main path = **ET packet-framed buffering** (above); this note is only for the raw-byte replay case.

If instead you replay raw VT bytes from a ring buffer, **feed `ESC [ ! p` (DECSTR, Soft Terminal Reset) into `ghostty_surface_feed_data` before replaying the tail**. DECSTR resets cursor visibility, insert/origin/autowrap modes, G0–G3, SGR, cursor home, scroll margins — the modal state corrupted by a mid-sequence replay. (Opaque libghostty has no `softReset()` → push the DECSTR bytes into the stream; Ghostty's VT parser handles them.) DECSTR doesn't fully cover an escape sequence straddling the wrap point → combine with a **sync-point marker** (host periodically emits a no-op DCS; client scans for the last marker and discards everything before it). The packet-framed main path replays on packet boundaries, so this hazard **never arises** — why ET-style was chosen.

#### Persistent PTY — survives every disconnect

The PTY/shell must live independently of the TCP connection: a **helper process holds the master FD**, not a per-client connection handler. Because the helper owns the master FD, closing the client socket does **not** cause `SIGHUP` to the shell's process group. Two ways: (a) a **persistent host daemon** (launchd `KeepAlive=true`) holding `[UUID: PTYSession]`; (b) **tmux** (v2 upgrade) — the server process holds every master FD, sessions live indefinitely, reconnect = `tmux -CC attach`, plus server-side scrollback + window/pane mapping for free (iTerm2's `TmuxGateway.m`, ~884 lines, is the reference). Add a configurable idle-kill timer (e.g. 48h) to avoid orphaned shells.

#### iOS lifecycle + roaming

- **iOS background**: ~30s budget (`beginBackgroundTask`); sockets reclaimed by the OS on suspend (TN2277). **Do NOT try to keep the socket alive across suspension.** Pattern: scenePhase `.background` → `connection.cancel()` + mark disconnected; `.active` → new `NWConnection` + ET sequence-exchange resume. For a brief network gap (no lifecycle event) → rely on `NWConnection` `.waiting` + `waitingForConnectivity` auto-advancing to `.ready`.
- **macOS host wake**: lid-close **forces sleep regardless of** `IOPMAssertion` type. Subscribe to **`NSWorkspaceDidWakeNotification`** (the NSWorkspace notification center, not defaultCenter) → re-listen the `NWListener`, check `NWPathMonitor` before accepting. `NSActivityUserInitiated` blocks App Nap + idle sleep but not lid-close sleep. (📋 Verify: whether a non-GUI launchd KeepAlive daemon reliably receives `NSWorkspace` notifications — needs a running CFRunLoop.)
- **macOS client Wi-Fi↔Ethernet roaming**: `NWPathMonitor.pathUpdateHandler` fires on dock/undock; `NWConnection.viabilityUpdateHandler(false)` signals cancel + new connection + sequence exchange. Because the `BackedWriter` buffer persists in-process (not tied to a socket), catchup delivers buffered output right after 1 RTT.

---

### Recommendation summary (implementation-ready)

| Item | Decision |
|----------|-----------|
| PTY allocation | `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()` (avoids the fork-in-Swift hazard); or `forkpty()` with strict fork-then-exec-immediately |
| Async I/O | `DispatchIO(.stream)` lowWater=1, highWater=128KB, close in the cleanupHandler |
| Resize | `ioctl(TIOCSWINSZ)` → SIGWINCH |
| Sandbox | host **non-sandboxed** Developer ID, Hardened Runtime, runs as the logged-in user |
| Transport | **TCP** over Network.framework, type-prefix framing (ttyd-style), **no app-layer TLS** (the mesh encrypts, [13]). **NO mosh SSP/UDP** |
| Local echo | ⏸️ DEFERRED (assume P2P; revisit only if relayed) |
| Client emulator | **libghostty** full surface (self-owned patch, Metal GPU, ligatures OK) |
| Scrollback | client-side (the libghostty surface keeps scrollback internally); stateless server + ET-style seq replay buffer for reconnect ([17 §2.3]) |
| Reconnect | ET packet-framed sequence buffer (64MB cap; mind the 4MB disconnect SKIPPED); persistent PTY helper (v1) → tmux `-CC` (v2) |
| iOS/roaming | eager reconnect on scenePhase `.active`; `NWPathMonitor` + `NSWorkspaceDidWakeNotification` |

Primary sources: [SwiftTerm Pty.swift / LocalProcess.swift / Terminal.swift / AppleTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm), [mosh terminaloverlay.cc / transportsender-impl.h / network.cc](https://github.com/mobile-shell/mosh), [Eternal Terminal BackedWriter/BackedReader/Connection](https://github.com/MisterTea/EternalTerminal), [ttyd protocol.c](https://github.com/tsl0922/ttyd), [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess), [nosshtradamus](https://github.com/thyth/nosshtradamus), Apple [Network.framework](https://developer.apple.com/documentation/network/nwconnection) / [forum thread 747499](https://developer.apple.com/forums/thread/747499) / [thread 734230](https://developer.apple.com/forums/thread/734230), XNU `bsd/sys/termios.h`.

---

## GUI video path (4:2:0 is good enough) — simplified

> Re-scope: the "text crispness" requirement is **dropped** for the video path. Every GUI-window pane (VS Code, Xcode, browser...) goes through **ScreenCaptureKit → VideoToolbox HEVC 4:2:0 → Network.framework → decode → Metal**. The terminal path carries the demanding text, so the codec no longer strains for text. Mindset: **idle-efficiency + encode-on-change**, not a hard sub-16ms floor — render **feels-local at 60 fps** while idle-skip keeps bandwidth near zero whenever the screen is static (most of the time for coding).

> **Implementation note.** Over plain UDP the built video path adds **FEC** (Reed–Solomon over GF(2⁸), NEON-accelerated, adaptive tiering: `FECScheme` + `AdaptiveFECPolicy`; `m=1` byte-identical to the old single-loss XOR parity, `m≥2` recovers multiple losses per group), **adaptive bitrate / congestion control** (`LiveCongestionController` + `LiveBitratePolicy`), **LTR** loss recovery, a client-side **cursor** side-channel (strip from capture, composite client-side → pointer latency = RTT), a **window-geometry** channel, and display-refresh frame pacing. Packetization/FEC/reassembly + those controllers run in the Rust core (`rust/slopdesk-core`) behind the C-ABI; the codec config below is what the Swift shell drives. (FEC + ABR exist *because* the link is not loss-free — not optional.)

---

### TL;DR (GUI video path)

- **4:2:0 HEVC is good enough** for reading code in a GUI window. Luma (Y) keeps full resolution → glyph edges stay sharp; only chroma (Cb/Cr) is subsampled → slight color fringing at harsh boundaries. Dark themes make fringing even less visible. (`claim_to_verify`: "tolerable" is subjective; user-test at the actual resolution/bitrate — see §6.)
- **4:4:4 is dropped outright** — **Apple's HW encoder has no 4:4:4 for HEVC.** The complete `kVTProfileLevel_HEVC_*` set (through iOS/visionOS 26, 2025) is only Main / Main10 / Main42210 / Monochrome / Monochrome10 — **no** SCC or 4:4:4 streaming profile. A hardware limit, not a config choice.
- **The levers that actually matter are idle-efficiency:** `SCFrameStatus.idle` (zero encode when static) + `dirtyRects` (encode changed regions) + a **60 fps default** with idle-skip (30 fps reads stale on scroll/motion, so don't lower the cap — idle-skip already drives bandwidth to ~0 when static) + CQ. A code screen is mostly still → average bitrate approaches 0 when idle, bursting only on typing/scrolling/compiling.

---

### 1. Why 4:2:0 is good enough (and 4:4:4 is dropped)

### 1.1 Mechanism: luma stays sharp, only chroma is subsampled

ScreenCaptureKit captures `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) — the CPU-cheapest format for VideoToolbox HEVC. 4:2:0 only reduces chroma resolution (H+V); **luma stays full resolution**, and glyph edges (light/dark contrast) live mostly in luma:

- White/gray text on a dark background (VS Code Dark+, Xcode dark): virtually no visible harm.
- Colored text on a harshly colored background (red/green syntax on light): slight chroma fringing, "softer" but comfortable for daily coding.

Sources: ScreenCaptureKit pixel-format guidance (WWDC22 10155); Microsoft Azure Virtual Desktop graphics-encoding docs.

### 1.2 4:4:4 is dropped because of hardware, not because of the re-scope

So nobody later "turns 4:4:4 back on for sharpness":

- **Verified (confidence: high):** the complete `kVTProfileLevel_HEVC_*` list in `VTCompressionProperties.h` across every SDK from macOS 10.13 / iOS 11 through iOS/visionOS 26 (2025) is only `Main_AutoLevel` (8-bit 4:2:0), `Main10_AutoLevel` (10-bit 4:2:0), `Main42210_AutoLevel` (10-bit 4:2:2), `Monochrome`, `Monochrome10`. **No** `kVTProfileLevel_HEVC_SCC_*` or 4:4:4 variant. FFmpeg's `videotoolboxenc.c` loads exactly those three HEVC symbols. (Sources: VTCompressionProperties.h in xybp888/iOS-SDKs; FFmpeg videotoolboxenc.c lines 122-197.)
- **HEVC-SCC (palette mode, intra block copy) is also absent** — the screen-content tools sit outside both the API surface and (by inference) the hardware block. Parsec/Moonlight treat 4:4:4 as the #1 text lever, enabled by Intel/Nvidia 4:4:4 HW encode — which Apple lacks.

→ Since the terminal path carries the demanding text, **accepting 4:2:0 for the GUI is the right decision**, not a reluctant compromise.

---

### 2. Lever #1 — `SCFrameStatus.idle`: zero encode when static

Every `CMSampleBuffer` carries an `SCStreamFrameInfo` attachment; the `.status` key returns `SCFrameStatus`. WWDC22 (session 10156): *"An idle frame status means the video sample hasn't changed, so there's no new IOSurface."*

Guard **before** submitting to the encode queue:

```swift
guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, ...),
      let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
      SCFrameStatus(rawValue: statusRaw) == .complete else {
    return   // .idle / .blank / .suspended → drop, do NOT encode
}
// only .complete carries a new IOSurface → submit to VTCompressionSessionEncodeFrame
```

**Caveats (verdict: uncertain, confidence: medium):**
- "No new IOSurface" is Apple-confirmed. But **"zero GPU work / zero encode" is NOT an OS property** — ScreenCaptureKit does not encode; encoding is the app's job. Idle = zero encode **only if** the app applies the `status == .complete` guard before every VideoToolbox call (Apple's sample-code pattern).
- The callback **still fires** for idle frames (Apple sample code guards `status == .complete else { return }`; OBS routes every callback then nil-checks the IOSurface). So **do not assume** the encode thread auto-sleeps when idle — sleep it yourself based on time since the last `.complete` (`open_question`: does the idle callback rate follow `minimumFrameInterval` or get suppressed — Apple forum thread/718356 unclear).

Impact: while reading/thinking/debugging the screen sits still for seconds → encode+transmit bitrate **drops to 0** naturally (OS signals idle directly — no timers/polling).

---

### 3. Lever #2 — `dirtyRects`: region-based encode-on-change

`SCStreamFrameInfo.dirtyRects` (key `.dirtyRects`) returns `[CGRect]` in content coordinates covering exactly the regions changed since the previous frame (cursor blink, one line, a gutter scroll). WWDC22 (10155): *"use dirty rects to only encode and transmit the regions with new updates, and copy the updates onto the previous frame on the receiver side."*

| Pattern | How | Assessment |
|---------|----------|----------|
| **A — full-frame + attached dirtyRects** | Encode the full frame with VideoToolbox, send the dirtyRects list so the receiver composites only changed regions onto its cached previous frame | Simple, fits VideoToolbox (whole-frame encode). **Recommended for v1.** |
| **B — crop-encode only the dirty regions** | Encode/transmit tiles of the changed regions | Needs tiling / macroblock control VideoToolbox does not expose → complex. Postponed. |

Impact: when only one pane changes (autocomplete popup, build-output scroll while another pane is static), the payload drops sharply. Combined with idle-skip → session-average bitrate sits far below peak.

`open_question`: what fraction of a frame is actually dirty in a real coding session (autocomplete, cursor blink, scroll) — decides whether pattern B beats full-frame VBR. Needs measurement.

---

### 4. Lever #3 — fps cap + idle-skip

`SCStreamConfiguration.minimumFrameInterval` (CMTime) caps frame delivery. **Decision: default 60 fps** — 30 fps reads stale on scroll/motion, so fps *does* matter; idle-skip (not a low cap) keeps bandwidth near zero. (WWDC22 10156 suggests 10fps for very static text, but that reads laggy the moment anything scrolls.)

```swift
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)   // 60 fps default; idle-skip keeps near-zero when static
config.queueDepth = 3                                            // true default=8; use 2–3 for low latency ([11]); releases surfaces fast
config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12 4:2:0
```

- **idle-skip** drives bandwidth to ~0 across static periods (the dominant lever); **minimumFrameInterval** sets the motion ceiling — kept at 60 so scrolling/typing feels local. 60 encodes/second when active, **0 at rest**.
- `queueDepth`: a frame must be processed + released within `minimumFrameInterval × (queueDepth − 1)` seconds to avoid drops. On `.idle` return immediately without holding the surface; on `.complete` submit, then release once the encoder consumes the pixels (VideoToolbox retains internally).

---

### 5. VideoToolbox configuration for static screens

Keep the pipeline on the Apple Silicon Media Engine (HEVC encode off the P/E cores → low battery/heat, true to a laptop coding tool):

```swift
// Encoder spec
kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = kCFBooleanTrue

// Properties
kVTCompressionPropertyKey_ProfileLevel       = kVTProfileLevel_HEVC_Main_AutoLevel   // 4:2:0, auto level
kVTCompressionPropertyKey_RealTime           = kCFBooleanTrue
kVTCompressionPropertyKey_AllowFrameReordering = kCFBooleanFalse                      // P-frames only, no B-frames, no lookahead bubble
kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration = 2.0                           // an I-frame every ~2s for error repair, without keyframe bloat
```

**Rate-control mode by environment:**

- **LAN (default): constant quality** — `kVTCompressionPropertyKey_Quality = 0.6`. Easier to tune than bitrate+DataRateLimits: static frames produce tiny NALUs, bursts (compile/scroll) take all the bits they need. On LAN bandwidth isn't the bottleneck → CQ fits "near-zero when idle, enough bits when active".
  - **Verified (confidence: medium):** CQ exists only on **Apple Silicon (macOS ARM64)**, not Intel/T2. FFmpeg gates it `!TARGET_OS_IPHONE && TARGET_CPU_ARM64` ("constant quality only on Macs with Apple Silicon"). Apple doesn't document this key per-chip → **feature-detect / test in practice**, fallback to bitrate mode on Intel.
- **WAN / constrained bandwidth (if expanded later):** `AverageBitRate` + `DataRateLimits` (CFArray `[peak_bytes, duration_seconds]` for bursts).

**Low-latency rate control with HEVC (verdict: uncertain — not guaranteed):**
- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` **has empirical evidence with HEVC on Apple Silicon** (FFmpeg patch merged, commit d87210745e, 9/2025, gated `TARGET_CPU_ARM64`) — but **Apple has not documented** HEVC for this key; WWDC21 says "supported video codec type in this mode is H.264". The header declares the symbol since macOS 11.3 with no codec constraint, and doesn't confirm HEVC.
- → Under this re-scope, low-latency RC is **no longer load-bearing**: what was dropped is chasing a hard sub-16ms motion-to-photon *floor* (and 120fps), not fps itself — 60 is the default. Enable for HEVC-on-Apple-Silicon if testing shows it's fine, but **not required**. `AllowFrameReordering=false` (no B-frames) already suffices for input responsiveness.

`claim_to_verify`: does `kVTCompressionPropertyKey_AllowTemporalCompression=false` (disabling inter-frame) for HEVC make VideoToolbox fall back to software encode — WWDC21 demonstrates for H.264; unverified for HEVC. Use only if every frame truly must encode independently.

---

### 6. Minimum quality bar for reading code

`open_question` with no hard numbers from the sources — a framework inferred from HEVC VBR/CQ behavior; **must be user-tested at the actual target configuration**:

- **Resolution:** capture per-window at the window's **backing resolution** (`width/height = logical size × NSScreen.scaleFactor`), don't hardcode 2×. Full retina scale → more chroma pixels per glyph → 4:2:0 hurts less. Capture exactly 1 window (`SCContentFilter(desktopIndependentWindow:)`), not the full desktop: a 1920×1080 window on a 2560×1440 display already cuts ~44% of the pixels to encode.
- **Bitrate (estimate, derived — not Apple-measured):** HEVC 4:2:0 1080p VBR for a static code window ~ **0–50 kbps when idle**, **~500 kbps–2 Mbps during active typing/scrolling**. With CQ, bitrate tracks content complexity; no ceiling needed on LAN.
- **Open question to measure:** the minimum bitrate at which 12pt code in VS Code Dark+ at 2560×1440 (logical) is still comfortably readable when rendered at 1920×1200 on an iPad? **No number in the sources** — bench it for real.

Reference comparison: HEVC saves ~25–50% bitrate vs H.264 at equivalent quality (Azure Virtual Desktop docs). On Apple Silicon, HEVC 1080p60 encode takes ~18ms/frame, capture overhead ~1.9% of one CPU core at 60fps (Lumen/Sunshine-fork numbers + WWDC22; `claim_to_verify` — third-party numbers varying with quality/complexity).

---

### 7. How this differs from the earlier latency-obsessed docs

| Old mindset (10-latency-optimization, 11-absolute-latency) | New mindset (hybrid re-scope) |
|---|---|
| Motion-to-photon < 16ms as the top goal | **Hard floor dropped.** Screen mostly static; typing/cursor responsiveness handled by the **PTY/terminal path** (bytes into PTY stdin, no CGEvent), not video. GUI path targets feels-local, not a sub-16ms floor |
| 120fps / ProMotion / beam-racing the floor | **Dropped** (120fps + beam-racing). But fps matters: **default 60 fps** (30 reads stale on motion) + **idle-efficiency** + encode-on-change; idle-skip, not a low cap, saves bandwidth |
| 4:4:4 / text sharpness as lever #1 | **4:4:4 dropped outright** (no HW support). Demanding text goes via the terminal path. 4:2:0 good enough for GUI |
| Low-latency rate control as load-bearing | Demoted to "nice-to-have, uncertain for HEVC". `AllowFrameReordering=false` suffices |
| Optimize every frame | Optimize for **most frames being idle**: the `SCFrameStatus.idle` guard + `dirtyRects` are the center of gravity |

Kept invariants: HW HEVC encode on the Apple Silicon Media Engine (low battery/heat), per-window capture via `SCContentFilter(desktopIndependentWindow:)`, NV12 4:2:0 input, P-frames-only.

---

### 8. Remaining open questions

- Does `SCFrameStatus.idle` deliver callbacks steadily at `minimumFrameInterval`, or are they suppressed? Affects whether the encode thread can sleep (Apple forum thread/718356 ambiguous).
- Does VideoToolbox HEVC on Apple Silicon expose `kVTCompressionPropertyKey_ConstantBitRate`, or only `AverageBitRate` + `DataRateLimits`? CBR helps network buffering but may hurt idle-efficiency.
- Does HEVC hardware decode on iPad add latency that cancels the encode savings on the Mac side vs H.264? Expected very small, but no number in the sources.
- Is 4:2:0 fringing on dark-theme VS Code/Xcode truly "tolerable" at the target resolution/bitrate? **Subjective judgment — user-test required.**

---


---

## Roadmap & docs updates for the hybrid architecture

> Overrides the phase direction of [07-roadmap.md](07-roadmap.md) and flags over-engineering in [05](05-input-window-control.md), [09](09-codec-choice.md), [11](11-absolute-latency.md) for the new **hybrid** architecture: **terminal path (PTY byte stream like SSH/mosh, rendered with libghostty)** + **GUI window path (ScreenCaptureKit -> VideoToolbox HEVC 4:2:0)**. Claims track the verified corpus; `refuted`/`uncertain` items are reflected as corrections/uncertainty.

---

### 1. Technique ranking for the hybrid tool (biggest levers -> marginal)

Order = (value for daily coding) × (certainty) ÷ (risk + effort). The "Apple" column = native support level per the corpus.

| # | Technique | Why it wins big | Apple | Difficulty | Risk |
|---|----------|-------------------|-------|-----|--------|
| **1** | **PTY bridge text-path** (`forkpty()`/`openpty()` + DispatchIO + VT byte stream over TCP, client render) | **Entirely sidesteps input-injection**: a keystroke is just bytes to the PTY master fd — no CGEvent/Accessibility/activate-then-control/TCC. Text crisp **by construction**. Near-zero idle (a quiet PTY produces no byte flow). Bandwidth ~36–52 bytes/keystroke. | native | low | low |
| **2** | **libghostty as the client renderer** (full surface + **self-owned external-backend patch**, ref daiimus External.zig; `ghostty_surface_feed_data` ← network, write-callback → host) | Ghostty-class rendering: Metal GPU, highest VT fidelity, Kitty graphics, ligatures. Proven on iOS (VVTerm/Moshi). Price: ~1–3 weeks standing up the Zig build + own patch + vendored XCFramework. Wrapped behind `TerminalRendering` to isolate the C-ABI. | native (via self-owned patch) | **high** | medium (ABI-instability tax + self-rebased patch; bus factor avoided) |
| **3** | **TCP stream transport over Network.framework** (`NWConnection`/`NWListener` + 1-byte type + 4-byte big-endian length framing, ttyd-style) | Simplest fit for LAN: RTT <1ms so TCP head-of-line blocking negligible; perfect idle efficiency (no PTY output → no bytes flow). No mosh SSP/UDP. | native | low | low |
| **4** | **Persistent PTY via a helper process holding the master fd** (launchd agent `KeepAlive`, or tmux) | The shell survives every client disconnect (iPad sleep, lid close, Wi-Fi handoff). The master fd belongs to the helper — not the TCP handler — so closing the socket sends no SIGHUP. | native | medium | medium |
| **5** | **ET-style packet-framed ring buffer + sequence-number ACK catchup** (BackedWriter/BackedReader) | Seamless reconnect after LAN interruptions. **Replay on packet boundaries** structurally eliminates a replay cutting mid-escape-sequence (emulator corruption). | partial | medium | medium |
| **6** | **iOS eager-reconnect on foreground** (`scenePhase .active` → new NWConnection + sequence exchange; do **not** keep the socket alive across suspension) | Matches iOS reality: the OS reclaims sockets on suspend (~30s background budget). Reconnect is the normal fast path, not exceptional recovery. | native | medium | medium |
| **7** | **Clipboard sync: OSC 52** for the terminal path (libghostty OSC 52 action callback; SwiftTerm `clipboardCopy`/`clipboardRead` only a *citation*) | Host→client copy nearly free, riding the PTY byte stream. tmux/Neovim can emit OSC 52 today. | native | low | medium (read = exfiltration, default-deny) |
| **8** | **ScreenCaptureKit per-window + `SCFrameStatus.idle` skip + `dirtyRects`** (GUI video path) | Near-zero bandwidth on a static screen — the most important idle lever. `guard status == .complete` before encode = zero encode when idle. | native | medium | low |
| **9** | **VideoToolbox HEVC 4:2:0, `AllowFrameReordering=false`, `RealTime=true`, quality-mode** (GUI path) | HW encode on the Media Engine (~0% of a CPU core), P-frames-only (no B-frame lookahead). 4:2:0 **acceptable** (text-crispness constraint dropped). | native | medium | low |
| **10** | **CGEvent/SkyLight input injection** (GUI video path) | Needed only for **GUI windows**, not the terminal. Retains the full activate-then-control + private SPI complexity. | partial/unsupported | high | **high** (Electron mouse reject, private API, no MAS) |
| **11** | **Mosh SSP + speculative local echo** (PredictionEngine) | **Not needed on LAN.** Adaptive mode's `srtt_trigger` only fires when `send_interval > 30ms`; LAN clamps at 20ms → local echo **dormant** (verified). Instant echo needs `DisplayPreference=Always`. Marginal for LAN. | native (logic) | high | medium |

**Uncertainty/correction notes tracking the corpus:**
- `forkpty()` from Swift is **safe** if the child `execve()`s immediately (fork-then-exec) and the parent only takes the master fd — the "unsafe to call from Swift" claim **refuted** at the call-site; the real hazard is only running the Swift/ObjC runtime in the child *before* exec ([forums.swift.org/t/51457], [developer.apple.com/forums/thread/747499]). Apple's recommended workaround: `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()` — where SwiftTerm is migrating (currently guarded `#if false //canImport(Subprocess)`).
- `posix_openpt()` is **not "broken"** on macOS (refuted) — the only real limitation is `fcntl(O_NONBLOCK)` on the master fd failing with EINVAL before the slave is opened; `openpty()` avoids it because it opens the slave itself ([apple-oss Libc/util/pty.c]).
- HEVC + `EnableLowLatencyRateControl` on Apple Silicon: **uncertain/empirical** — confirmed via an FFmpeg patch (`TARGET_CPU_ARM64`, commit d87210745e, 9/2025) but **Apple does not document HEVC** for this property (WWDC21 says H.264 only). Usable, but feature-detect at runtime ([VTCompressionProperties.h]).

---

### 2. "Do first" — bootstrap shortlist

The minimal set for a daily-usable tool, lowest risk / highest value:

1. **PTY bridge on the host** — `openpty()` + `posix_spawn` (login_tty, `POSIX_SPAWN_SETSID`), env `TERM=xterm-ghostty`, `LANG=en_US.UTF-8`, `COLORTERM=truecolor`, the `IUTF8` termios flag (present on Darwin: `IUTF8 = 0x00004000` in XNU `bsd/sys/termios.h`), prepend `-` to argv[0] for a login shell. Read the master fd with `DispatchIO(.stream, lowWater:1, highWater:131072)`.
2. **Resize**: `ioctl(masterFd, TIOCSWINSZ, &winsize)` when the client reports a new size → SIGWINCH (SwiftTerm `sizeChanged` delegate → resize message → host ioctl).
3. **Transport**: `NWConnection`/`NWListener` TCP, 1-byte-type framing (0=terminal data, 1=resize) + 4-byte length. **No app-layer TLS** — the mesh encrypts; authorization via the mesh ACL ([13]).
4. **Client libghostty** (full surface + **self-owned external-backend patch**, ref daiimus External.zig): `ghostty_surface_feed_data` ← NWConnection receive loop; write-callback (`use_custom_io=true`) → NWConnection → host PTY stdin. Build `GhosttyKit.xcframework` (zig), vendor + pin upstream SHA, re-apply the patch on bumps. Wrap behind `TerminalRendering`.
5. **Persistent PTY**: the host helper is a launchd agent with `KeepAlive=true` holding all master fds; PTYs survive disconnects.
6. **Minimal reconnect**: iOS `scenePhase .active` → reconnect; macOS client `NWPathMonitor.pathUpdateHandler` → reconnect on Wi-Fi↔Ethernet changes.

> ⚠️ **Threading caveat (load-bearing, corpus `uncertain`):** `feed(byteArray:)` is documented "can be invoked from a background thread", **but** `feedPrepare()` mutates `selection.active`/`search.invalidate()` and `queuePendingDisplay()` reads/writes `pendingDisplay: Bool` **without a lock** on the caller's thread → a real data race. Mitigation: hop to the main queue before `feed()` from the network receive loop, or serialize. Stress-test before shipping.

> ℹ️ **Ligatures:** libghostty (Ghostty) handles ligatures correctly via HarfBuzz shaping — no column drift.

---

### 3. How the docs change

#### 3.1. [05-input-window-control.md] — the biggest risk **disappears for the terminal path**

Doc 05 opens with "This is the project's biggest technical risk". With hybrid, **that is now true only for the GUI video path**:

- **The terminal path touches no CGEvent/AX/activate-then-control.** Input = bytes to the PTY master fd via `DispatchIO.write`. No TCC Accessibility, no `CGEventPostToPid`, no `AXUIElement`↔`CGWindowID` matching (the "genuinely fragile" point doc 05 §4 admits), no cooperative-activation caveat (doc 05 §4: activation "FAILS when triggered by a timer/network"). **That entire risk chain vanishes for the bulk of the coding workflow (terminal/Neovim/tmux/git/build).**
- **Phase 0 gate:** the 0.4–0.6 spikes in [07-roadmap.md] (AXRaise on the right window, CGEventPostToPid clicking accurately, activation rate from a network callback) **are no longer project-blocking gates**. They drop to prerequisites for the **GUI video path (a later phase)**, not survival conditions for the MVP.
- **Change doc 05:** add a top banner: "Applies to the GUI window path; the terminal path sidesteps injection entirely — see PTY bridge". Keep the technical content (still valid for VS Code/Xcode windows) but lower the risk priority.
- **Electron correction (already in the [05] banner):** keyboard injection via `CGEventPostToPid` IS accepted by Electron/VS Code; only the **mouse** is rejected (needs SkyLight SPI) — verify on macOS 26.

#### 3.2. [09-codec-choice.md] — the 4:4:4 / text-crispness problem is **dropped outright**

Doc 09's TL;DR reads "The real text-quality ceiling is 4:2:0 chroma ... lever #1 ... the thing Apple does not have". With hybrid, **no longer the central problem**:

- **Text crispness is no longer priority #1.** The codec-stressing text (terminal, code) **goes via the PTY path rendered by libghostty — crisp, no codec involved**. Video only serves GUI windows (VS Code/Xcode editor views), where **4:2:0 HEVC is acceptable**.
- **Over-engineering to mark DROP in doc 09:**
  - §2 "Available levers" item 3 — **"Software encode 4:4:4 ultra-text tier"**: drop entirely. The 4:4:4 problem is dropped.
  - §2 item 1 — **HEVC 10-bit (Main 10) by default "for sharper edges"**: demote to optional. VideoToolbox has no HEVC-SCC (palette/intra-block-copy — claim `confirmed`: no `kVTProfileLevel_HEVC_SCC_*` in any SDK). **HEVC Main 8-bit 4:2:0** is enough; 10-bit is a marginal tweak.
  - **New recommendation:** `kVTCompressionPropertyKey_Quality = 0.6` (constant-quality, **Apple Silicon macOS ARM64 only** — FFmpeg `vtenc_qscale_enabled()` gates `!TARGET_OS_IPHONE && TARGET_CPU_ARM64`, `confirmed`) + `pixelFormat = 420YpCbCr8BiPlanarVideoRange` + `minimumFrameInterval = CMTime(1, 60)` (default 60 fps — 30 reads stale; idle-skip, not a low cap, saves the bandwidth) instead of optimizing chroma.
- **Change doc 09:** rewrite the TL;DR as "the GUI window path uses HEVC 4:2:0 8-bit quality-mode; text-heavy content goes via the PTY path with no codec". Keep the Parsec/Moonlight 4:4:4 comparison as historical context, noting "does not apply to hybrid because text moved to the terminal path".

#### 3.3. [11-absolute-latency.md] + [01 §5 latency budget] — the <16ms floor / 120fps / vsync are **over-engineering**

Doc 11 is the "deepest study (73 agents)" of the **absolute latency floor**: a 10–16ms floor @120fps ProMotion, capture-vsync + scanout-vsync dominant, beam-racing, `CAMetalDisplayLink preferredFrameLatency=1`. Doc 01 §5 targets "glass-to-glass ~30–50ms, 60fps". **For the hybrid coding profile, downgrade this whole layer:**

- **The hard sub-16ms motion-to-photon floor is no longer a goal** (README: coding tolerates 40–80ms). Therefore:
  - **DROP**: the 10–14ms floor, the 120fps/ProMotion path (doc 11's @120fps budget; doc 01 §5's "ProMotion 120Hz" note — README already says "120fps/ProMotion: dropped").
  - **DROP**: beam-racing, `CAMetalDisplayLink preferredFrameLatency=1`, slice/sub-frame pipelining ("Slice / sub-frame pipelining is NOT available through the public VideoToolbox API" — `refuted`, drop anyway).
  - **DROP for the terminal path**: the vsync-dominated budget entirely. **Terminal-path latency = network RTT + PTY round-trip (~1–5ms LAN), with NO capture-vsync, no scanout coupling, no encode/decode.** Doc 11's "compositor capture vsync + scanout vsync are the two incompressible costs" **applies only to the GUI video path.**
  - **What stays: fps still matters — dropped is the floor and 120fps, not fps.** The correction "`minimumFrameInterval` on macOS 15+ silently defaults to 1/60" lines up: GUI path **default 60 fps** (30 reads stale; idle-skip, not a low cap, saves bandwidth). `(1/fps)×0.9` (OBS PR#11896), not `kCMTimeZero` (refuted).
- **Keep from doc 11 (valid, low-risk GUI path):** `queueDepth`'s true default is 8 (not 3), `2` valid for low latency; `AllowOpenGOP` defaults true → set `false`; `MaxFrameDelayCount=0`; **disable AWDL/`includePeerToPeer`** (40–336ms spikes — important for GUI video over Wi-Fi); idle-frame skip + dirtyRects.
- **Change doc 11:** banner "This floor analysis applies to the **GUI video path**. The terminal path (default, Phase 1) is dominated by network RTT, no vsync." Demote from "central study" to "reference for the later video phase".
- **Change doc 01 §5:** split the latency budget into 2 tables: (a) **Terminal path** = keystroke → PTY → byte stream → render, ~1–5ms LAN + optional local echo; (b) **GUI video path** = keep the 6-stage table but relax to a feels-local 40–80ms budget **at the 60 fps default** (drop the 120fps column).

---

### 4. Phased roadmap as it played out (history — overrode [07-roadmap.md])

> **This roadmap is now history.** The terminal text-path was built first (simpler + higher value + dodges the hardest injection problem); the GUI video path (old "Phase 4") has **since shipped and is co-equal** (panes on one canvas, routed by content). Preserved as the record of *why* it was built that way; no longer pending work.

The order was inverted: **the terminal text-path was Phase 1**. The GUI video path was sequenced into a later phase — and has since shipped.

```
Phase 1 (terminal PTY) ──▶ Phase 2 (persist+reconnect+clipboard) ──▶ Phase 3 (iOS client)
   high value, low risk        makes it "daily usable"                  device expansion
                                                                            │
                                            Phase 4 (GUI video) ◀───────────┘  <- injection risk concentrated here; now SHIPPED, co-equal
                                            Phase 5 (security + polish)
```

#### Phase 0 — Spike (focus shifted)
Remove the input-injection gate from its project-blocking position. New spikes:
- [ ] `openpty()` + `posix_spawn(createSession)` spawn a login shell, read the master fd via DispatchIO, echo bytes over TCP — verify the shell runs and vim/tmux render box-drawing correctly (env `LANG`/`IUTF8`). (forkpty-unsafe-from-Swift — resolved.)
- [ ] **libghostty spike:** apply the external-backend patch (ref daiimus External.zig / Lakr233 `0002-host-managed-io.patch`), build the XCFramework, feed a byte stream → render on macOS + an iOS device. Verify: fullscreen/alt-screen works, keys routed through `ghostty_surface_key` (kitty/DECCKM correct), action callbacks (COMMAND_FINISHED/PWD) fire.

> 🔬 **Phase 0 — "must measure on device" SPIKE checklist (gates; cannot be researched):**
> - [ ] **binary size** of `GhosttyKit.xcframework` (Metal renderer) on iOS — acceptable or not.
> - [ ] **OSC 133 shell-integration e2e** over the network (a real host shell emits → action callback fires on the client).
> - [ ] (codec, Phase 4) does `AllowTemporalCompression=false` force HEVC software encode (if so → use `MaxKeyFrameInterval=1` like FFmpeg); is `ConstantBitRate` for HEVC available (probe `VTSessionCopySupportedPropertyDictionary`, else `AverageBitRate`+`DataRateLimits`); does `ForceLTRRefresh` take `kCFBooleanTrue` or `@(1)`.
> - [ ] `mach_timebase` numer/denom on M2/M3/M4 — **always call the API, never hardcode 125/3**.
> - [ ] (codec, Phase 4) minimum bitrate for readable text + whether 4:2:0 fringing is "tolerable" — perceptual test on the target display.
> - [ ] `EnableLowLatencyRateControl` + HEVC + `EnableLTR` runtime feature-detect (`VTCopySupportedPropertyDictionaryForEncoder`).

#### Phase 1 — Terminal MVP (Mac host -> Mac client), **replacing the old "video MVP"**
- [ ] PTY bridge host: spawn the shell, stream bytes, `TIOCSWINSZ` resize.
- [ ] TCP transport framing (1-byte type + 4-byte length) over Network.framework.
- [ ] libghostty client: full surface + **self-owned external-backend patch** (XCFramework build), `feed_data` ← network / write-callback → host, wrapped behind `TerminalRendering`.
- [ ] Bonjour discovery: host advertises / client lists (kept from [03]).
- [ ] **Done:** open a host shell on a client Mac, type + run vim/tmux/git smoothly, absolutely crisp text, **not a single line of CGEvent/Accessibility**.

#### Phase 2 — Persistence, reconnect, clipboard
- [ ] Persistent PTY via a launchd agent holding the master fd (survives disconnects).
- [ ] ET-style packet-framed ring buffer + sequence-number catchup (corruption-free reconnect; if keeping a raw-byte ring buffer instead, prefix DECSTR `ESC[!p` before replaying the tail — `Terminal.softReset()`).
- [ ] Reconnect: iOS `scenePhase`, macOS `NWPathMonitor`; host `NSWorkspaceDidWakeNotification` re-listen after sleep.
- [ ] Clipboard OSC 52 (host→client copy free; read default-deny + permission prompt). Client→host paste uses **bracketed paste** (`ESC[200~`...`ESC[201~`) not an OSC 52 query, avoiding the ~10s Neovim freeze.
- [ ] **Done:** sessions survive iPad sleep / lid close / Wi-Fi handoff; two-way copy-paste.

#### Phase 3 — iOS / iPadOS client
- [ ] libghostty surface in a UIView (iOS), soft + hardware keyboard → PTY bytes (Ghostty supports the Kitty keyboard protocol for Neovim/Helix).
- [ ] iOS clipboard: `UIPasteboard.changedNotification`, export via `UIDocumentPickerViewController(forExporting:asCopy:true)`.
- [ ] **iOS UX (settled): libghostty TUI (same as desktop) + the read-only inspector [16] for a structured view.** Do NOT build SDK-driven panes (B2 dropped). The inspector provides native cards (tool/subagent/todo) without driving the agent → solves the "raw ANSI on a small screen" problem (Happy/Happier) without losing TUI fidelity.
- [ ] **Done:** code from an iPad over LAN, full terminal.

#### Phase 4 — GUI video path (sequenced here because the injection risk concentrates here — now SHIPPED & co-equal)
- [x] ScreenCaptureKit per-window + idle skip + dirtyRects + HEVC 4:2:0 8-bit quality-mode (new doc 09).
- [x] VideoToolbox decode + Metal render (feels-local 40–80ms at the 60 fps default, **no** 120fps/beam-racing — doc 11 demoted).
- [x] Input injection for GUI windows: activate-then-control + `CGEventPostToPid` (keyboard) + SkyLight SPI (Electron mouse) — **the truly "hardest" part of doc 05**, isolated to GUI-window panes, not the foundation.
- [x] **Done:** "mirror this window" for VS Code/Xcode/browser — a GUI-window pane co-equal with terminal panes on the canvas.

#### Phase 5 — Security & polish
- [ ] **Security = rely on the trusted private network (a WireGuard mesh, e.g. NetBird/Tailscale), do NOT encrypt at the app layer** — see [13](13-network-transport.md). WireGuard already provides E2E encryption + node auth; app-layer TLS/QUIC-crypto would be **redundant** (double encryption, pointless latency). → **Drop** Network.framework TLS / CryptoKit ECDH at the app layer.
  - **Authorization** uses the **mesh ACL** (deny-by-default, per-port): only open the app port from the client group → the host group. WireGuard authenticates the *node*; the ACL constrains *peer→port*.
  - ⚠️ **The mesh IS the security boundary** (unlike a bare LAN): PTY=RCE is confined to authorized peers (you control membership). Still worth having: a light app-level device allowlist + per-user auth if multiple users share the machine (mesh OIDC/SSO).
- [ ] File transfer (NWProtocolFramer multiplexed channel, or OSC 1337 for small files).
- [ ] Hardened Runtime + Developer ID + notarization (the host helper **cannot** be sandboxed since it spawns shells — ship outside MAS).
- [ ] ~~Speculative local echo~~ — **NOT needed.** Assume direct P2P over the mesh (~5–20ms, loss~0) → terminal = **TCP byte stream + libghostty render, no mosh/SSP, no predictive echo**. SSP's benefits only materialize when relayed, and we are **not engineering for relay** ([13 §4](13-network-transport.md)).

**Why the phases were inverted (corpus summary, history):** terminal was built first because it is (a) simpler than [video+injection] — just a byte stream, sidestepping input injection (the libghostty renderer is a one-time effort); (b) higher value — daily coding is terminal/Neovim/tmux/git/build, what every prior-art tool (Blink, code-server, JetBrains Gateway dropping Projector) converged on: "semantic/text streaming beats pixel streaming"; (c) it dodges the hardest problem — input injection. That same insight is why terminal panes render text via PTY+libghostty rather than video — a content-routing choice. The GUI video path serves windows with no semantic alternative; it has since shipped (the old Phase 4) and is now **co-equal** with the terminal path, both surfaced as panes on one canvas.
