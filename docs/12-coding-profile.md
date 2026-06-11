# 12 — Coding Profile: Hybrid Architecture (terminal text-path + GUI video-path)

> **STATUS: CURRENT** (deep-dive). Front door + decisions: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).
> This doc has 4 parts: **A. Hybrid architecture** (§1–7) · **B. Terminal text-streaming — design** · **C. GUI video path** (§1–8) · **D. Roadmap & docs updates**.

> Output of the research workflow (34 agents, 6 dimensions + verify + gap-fill) for the **daily coding** use-case. This document **replaces the "every window goes over video" assumption** of the earlier docs. Raw corpus: [research/hybrid-research-corpus.json](research/hybrid-research-corpus.json).

## TL;DR — architecture decision

The app splits into **two separate data paths**, routed per window/feature:

| | **Terminal text-path** (like SSH/mosh) | **GUI video-path** |
|--|---|---|
| Used for | shell / vim / tmux / CLI | VS Code, Xcode, browser, other GUI apps |
| Host | spawn login shell in a PTY (`forkpty`), stream the byte stream | ScreenCaptureKit captures 1 window |
| Client render | **libghostty** full surface (Metal GPU — the VVTerm stack), absolutely crisp | VideoToolbox decode → Metal (4:2:0, slightly soft — accepted) |
| Input | **bytes → PTY stdin** | CGEvent/Accessibility inject |
| Idle bandwidth | ~0 | ~0 (skip `.idle`) |

⭐ **Biggest insight:** the terminal path **completely bypasses macOS's input-injection problem** (no CGEvent, no TCC Accessibility, no activate-then-control, no AXUIElement mapping) — input is just bytes written to the PTY. → This is why we **build the terminal path FIRST**: simpler, crisper, and it cleanly sidesteps the project's biggest risk layer (R1/R2 in [08](08-risks-open-questions.md)).

> Prior-art lesson: VS Code Remote, JetBrains Gateway (dropped Projector pixel-streaming), Blink Shell — **nobody pixel-mirrors the code path**; semantic/text streaming wins. Pixels are only a fallback for GUI windows.


---

## Hybrid architecture: terminal text-path + GUI video-path

> **Important re-scope.** This document replaces the "every window goes over video" assumption of [01-architecture.md](01-architecture.md). The new design splits into **two fundamentally separate data paths**, routed per window / per feature. The use-case is **daily coding** over LAN — where most content is terminal/shell text, and the GUI editor (VS Code, Xcode) is only one part.

---

### 1. Two paths, one central insight

Every successful remote-coding tool converges on the same observation: **semantic/text streaming beats pixel streaming for the code path, and pixel streaming is kept only as a fallback for GUI windows** where no semantic option exists. JetBrains abandoned Projector (serializing AWT draw commands over WebSocket) in favor of the thin-client RD protocol because streaming draw commands still has higher latency than a dedicated semantic protocol (JetBrains says it outright: Projector has "higher UI latency and significantly more network bandwidth"). The best iPad→Mac setup today pairs Blink Shell (mosh/SSH) for the text path with VS Code Server (Remote Tunnels / code-server) for the IDE path — **neither side pixel-mirrors** ([JetBrains Gateway blog](https://blog.jetbrains.com/blog/2021/12/03/dive-into-jetbrains-gateway/), [blink.sh](https://blink.sh/), [code.visualstudio.com/docs/remote/vscode-server](https://code.visualstudio.com/docs/remote/vscode-server)).

PaneCast's hybrid architecture mirrors exactly that:

| | **TERMINAL text-path** | **GUI video-path** |
|--|------------------------|--------------------|
| Model | The app **owns the shell** like ssh/mosh: host spawns a login shell in a PTY, streams the byte stream (VT escape sequences) | Mirror 1 GUI window: capture → encode → stream → decode |
| Capture | `forkpty()` / `openpty()` from `<util.h>` (Darwin) | `ScreenCaptureKit` per-window |
| "Encode" | None — raw byte stream over the wire | `VideoToolbox` HEVC 4:2:0 (Media Engine) |
| Client render | **libghostty** full surface (Metal GPU, self-owned patch) | `VTDecompressionSession` → Metal |
| Input | **Bytes written straight to PTY stdin** | `CGEventPostToPid` / SkyLight SPI inject |
| Idle bandwidth | ~0 (the PTY produces no bytes while the shell is idle) | ~0 (`SCFrameStatus.idle` → skip encode) |
| Text quality | **Crisp by construction** | 4:2:0 (slightly soft, trade-off accepted) |

**Core insight — and the single biggest architectural win:** the terminal path **completely bypasses macOS's input-injection problem**. On the video path, typing a key into a host window requires synthesizing a CGEvent and calling `event.postToPid(pid)`, which:

- Requires the **Accessibility** permission (`kTCCServicePostEvent`), granted manually by the user in System Settings, and the **host app must NOT be sandboxed** for Accessibility to work fully.
- **Fails silently with Chromium/Electron apps** (VS Code renderer, Chrome, Slack) because the renderer IPC filter rejects synthetic events lacking hardware telemetry. Mouse is rejected more strictly than keyboard; right-click on web content gets coerced into left-click.
- For canvas/game-engine apps (Blender, Unity) you are forced into **activate-then-control** (raise the window for ~1 frame, then hand focus back) — breaking the host's "never steal focus" promise ([trycua: inside-macos-window-internals](https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md)).

The terminal path makes all of those constraints **disappear**: a keystroke is just bytes written to the PTY master file descriptor over a socket — **no CGEvent, no TCC Accessibility, no activate-then-control, no AXUIElement mapping**. This is not a runtime optimization but an architectural decision that removes an entire risk layer, both technical and distribution-related (Accessibility all but forces distribution outside the Mac App Store).

> ⚠️ **Important note on the "input bypass" (corpus, claim_to_verify partially verified):** the bypass lies in the fact that the **CLIENT side never injects into the host OS** — the client only sends bytes over the transport; the host writes those bytes into the PTY master fd. A prototype must confirm there is **no** CGEvent/Accessibility call anywhere in the client's key-handling path (libghostty write-callback → `NWConnection`). Easy to verify, since the client only emits bytes to `NWConnection`.

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

### 3.1 TERMINAL text-path (the primary path)

**Host PTY → byte stream → libghostty.** The host spawns a login shell in a PTY, reads the master fd (DispatchIO), and streams raw VT bytes; keystrokes are written straight to PTY stdin; resize via `TIOCSWINSZ`+SIGWINCH. **Full API details** (forkpty vs `openpty`+`posix_spawn`, DispatchIO, env vars + IUTF8, the corpus corrections) are **in Part B §"Terminal text-streaming — design" §1 below** — single source, not repeated here.

**Client renderer — libghostty (full surface) + SELF-OWNED external-backend patch. [DECISION FINAL]**
Use **libghostty** (the Ghostty engine) for both macOS + iOS — Ghostty-class rendering (Metal GPU, highest VT fidelity, Kitty graphics, ligatures). This is the stack VVTerm (open source) + Moshi/Echo/RootShell run in production on iOS, **a 1:1 match for our use-case** (the client has no local PTY; it renders a byte stream from the network).

> 🔑 **Integration approach (settled): SELF-OWN a minimal external-backend patch — do NOT depend on someone else's fork.** The trade-off was weighed: research recommended the SwiftTerm-engine+own-renderer path (mature, no immature lib), BUT we prioritize **Ghostty-class rendering**, so we keep full libghostty and **own a small patch ourselves** instead of depending on a fork. Why "depend on a fork" was rejected: both external-IO forks are **proven in shipping apps** ([17 §2.2] — VVTerm on `wiedymi/ghostty:custom-io`, Geistty on `daiimus/ghostty:ios-external-backend`) but both are **bus-factor 1**; `wiedymi:custom-io` lacks a resize callback, `daiimus` has **External.zig + resize callback + tests** (→ the better reference). Owning the patch (ref daiimus) = we control rebases, no dependence on anyone else.

**Data path (per VVTerm, confirmed by reading the source):** network bytes (NetBird/WireGuard TCP) → `ghostty_surface_feed_data()` → Ghostty's VT parse + Metal render; keystrokes go out via `ghostty_surface_set_write_callback` (`use_custom_io = true`) → write to `NWConnection` → PTY stdin on the host. Resize via the surface API → host `ioctl(TIOCSWINSZ)`.

> ✅ **Decision (verdict FLIPPED from SwiftTerm to libghostty, verified 2026).** All three old objections to libghostty have collapsed:
> - **iOS proven in production** — VVTerm (`vivy-company/vvterm`, source read: `ghostty_surface_new` on `GHOSTTY_PLATFORM_IOS`, **full surface**, not vt), Moshi (getmoshi.app, Ghostty 1.3.1), Echo, RootShell (`kitknox/rootshell`). Mitchell Hashimoto endorses.
> - **full libghostty CAN be fed network bytes** — via the external/custom-io backend (see "the price" #1). The "assumes it owns the PTY" objection is only true of upstream main.
> - **no tagged release yet** — still true (as of Ghostty 1.3.1) but does NOT block production.
> - **Use the FULL surface, NOT vt + own renderer** (take Ghostty's Metal renderer as-is; vt + own renderer is the road Spectty is on, and it is *not finished*).
>
> **Self-owned patch recipe (references, NOT direct dependencies):**
> 1. **External-backend patch (self-maintained) — feeding external bytes is patch-only** (upstream `ghostty-org/ghostty` only spawns PTYs; iOS cannot spawn processes, so an in-process patch is MANDATORY). Design reference: **`daiimus/ghostty ios-external-backend`** (`External.zig` ~470 LOC — **more complete**: resize callback + unit tests, has an ARCHITECTURE.md) over `wiedymi/ghostty custom-io` (~a dozen lines of delta, no resize, frozen). API: `use_custom_io` / `GHOSTTY_BACKEND_EXTERNAL` + `ghostty_surface_set_write_callback` + `ghostty_surface_feed_data`. **The real code delta is small (~hundreds of LOC)** → ownable + rebasable.
> 2. **Swift wrapper (self-written, ref Lakr233):** `Lakr233/libghostty-spm` has `InMemoryTerminalSession` (`write: (Data)->Void` + `receive(_ data: Data)` + UIKit input/IME/accessory/Metal display link) — **maps exactly to our use-case** → use as a reference for our own wrapper, do not depend on it.
> 3. **Build from Zig (self-hosted, ref Lakr233 `build.yml`):** `zig build -Demit-xcframework=true` (Zig 0.14+, Xcode 15+) → slices ios-arm64 / ios-arm64-sim / macos → vendor `GhosttyKit.xcframework`, **pin the upstream Ghostty commit SHA**, re-apply the patch on bumps. A build-time lock, not a runtime risk.
> 4. **Wrap behind a `TerminalRendering` protocol** (`feed(bytes)` + `onOutboundBytes`) to isolate the C-ABI binding.
>
> **The accepted price:** we dodge the **bus factor** (we own the patch), BUT we still carry the **ABI-instability tax** — the libghostty C-ABI has no stable release (`vt.h`/`ghostty.h`: "not a general purpose embedding API yet"), so every Ghostty bump means **rebase the patch + verify the ABI** + maintaining our own **Zig toolchain**. Effort: small patch + pipeline ~**1–3 engineer-weeks** up front, then hours per rebase on bumps.
>
> ✅ **Open questions RESOLVED (source read, verified — `research/resolve-open-questions-corpus.json`):**
> - (a) **Alt-screen (1049/smcup/rmcup) works CORRECTLY** through the external backend — all 3 feed functions land in the same Ghostty VT parser (`processOutput → terminal_stream.nextSlice`). → **fullscreen Claude Code OK.**
> - (b) **The external-backend API is OPAQUE** — it does NOT expose the parsed escape-stream / cell grid / cursor to the host app (`ghostty.h` only has `read_text`/`read_selection` snapshots + **action callbacks**: `COMMAND_FINISHED`+exit_code+duration, `PWD`, `SET_TITLE`, `PROGRESS_REPORT`, `CELL_SIZE`). → **Build block/status UI on action callbacks**, do NOT parse raw OSC client-side. (The separate `libghostty-vt` *does* have a grid API but it does not bridge to `ghostty_surface_t`.)
> - (c) **Keyboard: Ghostty encodes keys itself** via `ghostty_surface_key()` (reads live kitty_flags/DECCKM) → **route EVERY key through it**; ⚠️ **do NOT use Lakr233's bypass path** (`TerminalHardwareKeyRouter` hardcodes protocol-blind VT100 for nav keys when inMemory+no-modifier — wrong for a remote PTY in kitty/DECCKM mode).
> - (d) **TCP needs only simple buffering** — in-order lossless; an escape sequence may be split across 2 reads → the stateful VT parser holds state across reads (no need for seq/ACK/dedup/reorder).
> - (g) **Thread-safety: feed from a dedicated I/O thread, serialized per surface** (`processOutput` acquires `renderer_state.mutex`; concurrent feeds are safe across DIFFERENT surfaces, NOT on the same surface). VVTerm's `@MainActor` is a convention, not a requirement.
> - **Lakr233's `InMemoryTerminalSession`** = a wrapper over patch `0002-host-managed-io.patch` (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` + `write_buffer` + `process_exit`) → **use as a reference for our patch** (alongside daiimus External.zig).
>
> 🔬 **What ONLY A SPIKE can answer (measure on device):** (e) binary size of the XCFramework Metal renderer on iOS; (f) shell-integration OSC 133 e2e over the network. Codec spikes are at [§5/§6](#5-videotoolbox-configuration-for-static-screens) + the Phase 0 checklist at the end of this doc.

> ⚠️ **Threading with libghostty (verify on a real device):** calling `ghostty_surface_feed_data` from the network receive loop — confirm the thread-safety pattern VVTerm relies on (which queue calls feed; Ghostty manages its own render thread + Metal/IOSurface). *The SwiftTerm `feed()` data-race caveat NO LONGER applies* (we switched to libghostty).

**Scrollback:** a raw PTY has no scrollback. Simplest is **client-side**: the libghostty surface keeps a ring buffer of lines → the server stays a **stateless byte relay**, zero cost. If replay-on-reconnect is needed, keep a server-side ring buffer of raw bytes (~1MB) — far simpler than mosh-style state sync.

### 3.2 GUI video-path (fallback for GUI windows)

GUI video-path = **fallback** for GUI windows (VS Code/Xcode...). **Details** (per-window capture, idle-skip `SCFrameStatus.idle`, dirtyRects, HEVC 4:2:0 constant-quality encode + caveats) are in **Part C §"GUI video path"** below + [02](02-host-capture-encode.md)/[09](09-codec-choice.md). Input injection (CGEvent/SkyLight — **this path only**) is in [05](05-input-window-control.md).

---

### 4. Per-window routing: terminal-first

**Recommendation: lean terminal-first.** Corpus-backed reasons:

- **Market share & workflow.** VS Code holds 75.9% of IDE share but Vim/Neovim combined are ~38% usage (Stack Overflow 2025); terminal-centric workflows (Neovim + tmux, CLI, git, build systems) **account for most daily coding** on a remote Mac. The terminal path serves this bloc directly.
- **The terminal path is the stronger half in every respect:** sidesteps input-injection, near-zero bandwidth, text crisp by construction, clean APIs (`apple_support: native`, `difficulty: low`).
- **The video path is the harder half:** it retains all the CGEvent/SkyLight complexity, private SPIs, distribution risk, and 4:2:0 softness.

**Proposed ship order:**

1. **v1 — PTY shell first.** Low risk, clean APIs, tiny bandwidth. One `NWConnection` TCP byte relay + 1-byte-type framing.
2. **v2 — video mirroring as a secondary "mirror this window" feature**, started on demand via a window picker (like the `SCShareableContent` list — the safest & most explicit approach). Accept the CGEvent limitations, with a transparent fallback for non-terminal windows.

**How the user activates it** (open question, proposed direction): picking from a window picker is the safest & clearest option; avoid auto-detecting windows, because classifying "is this a terminal or a GUI editor" has no reliable API. The **terminal embedded in a GUI** case (VS Code's integrated terminal, Xcode console) is an open question — don't try to split it out; leave it inside that window's video path.

---

### 5. Wire protocol for the terminal path

The terminal path does **not** need the complexity of mosh SSP (state-diff UDP) on a LAN. With LAN RTT <1ms and loss <0.01%, TCP head-of-line blocking is **negligible** — raw byte streaming over TCP delivers equivalent performance for far less effort. (Mosh is only optimized for lossy WAN; its SEND_INTERVAL_MIN=20ms caps server→client at 50fps, meaningless on a LAN.)

**Proposed framing (ttyd-style, clean for multiplexing resize):**

```
1-byte msg type  (0 = PTY data, 1 = resize, ...)
4-byte big-endian payload length
payload bytes (raw PTY data / {cols,rows} for resize)
```

`NWConnection(.tcp)` over Network.framework: `NWListener` on the host, `NWConnection` on the client; manual 4-byte length framing or `NWProtocolFramer`. **No app-layer TLS** — WireGuard encrypts ([13]). Idle efficiency is excellent: the PTY master fd produces no bytes while the shell is idle → no bytes flow.

> **Local echo / prediction — NOT needed on LAN (verdict: confirmed).** Mosh's prediction engine in Adaptive mode is **completely dormant** when SRTT < ~60ms: `srtt_trigger` only turns on when `send_interval > 30ms`, and on LAN `send_interval` clamps to the 20ms floor. If we ever want instant echo, we must explicitly use `DisplayPreference = Always` (verified from `terminaloverlay.cc:434` + `transportsender.h:49`). With a PTY-over-LAN round-trip of 1–5ms, the server echo arrives before the user can notice → **drop prediction for v1**. The prediction engine is transport-agnostic (proven by nosshtradamus running it over SSH/TCP), so it can be added later if Wi-Fi needs it.

---

### 6. App Sandbox — a hard architectural constraint

**The host component must NOT be sandboxed.** A sandboxed app **cannot** `forkpty()`/`execvp()` an arbitrary login shell — the sandbox blocks exec of external processes not declared in entitlements, and no entitlement whitelists an arbitrary shell. Apple-accepted patterns:

1. **A non-sandboxed app via Developer ID** (outside the Mac App Store) — most dev tools (Xcode, VS Code, iTerm2, Terminal.app) are not sandboxed. **This is the standard route for dev tools** and removes every constraint on forkpty/PTY/sockets.
2. Or a non-sandboxed LaunchAgent/XPC helper talking to a sandboxed app.

Since the video path already needs non-sandboxed for Accessibility/CGEvent (see [06](06-permissions-distribution.md)), the decision "host = non-sandboxed Developer ID app" unifies both paths. The client viewer (render + send bytes only) **can** ship on the Mac App Store.

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

**Work for Phase 1 (terminal-first):**
- [ ] Non-sandboxed host helper: `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()`, env setup (`TERM`/`LANG`/`IUTF8`), `DispatchIO` read loop, `TIOCSWINSZ` resize.
- [ ] Wire protocol: 1-byte type + 4-byte length over `NWConnection` TCP; separate resize message.
- [ ] Client: **libghostty** full surface — **self-maintained external-backend patch** (ref `daiimus/ghostty` External.zig), build `GhosttyKit.xcframework` (zig), vendor + pin upstream SHA; `ghostty_surface_feed_data` ← network, write-callback → host PTY stdin, resize → surface API.
- [ ] Confirm via prototype: **no** CGEvent/Accessibility call anywhere in the client key path.
- [ ] (v2) Window picker to choose a GUI window → activate the video path on demand.

---


## Terminal text-streaming (SSH/mosh-class) — design

This is the **stronger half** of the hybrid architecture. Unlike the GUI window path (ScreenCaptureKit → HEVC → CGEvent inject), the terminal path **owns the shell** like `ssh`/`mosh`: the host spawns a login shell in a POSIX pseudo-terminal, streams the **raw byte stream** (VT escape sequences) to the client, and keystrokes are written **straight to PTY stdin**. The biggest architectural consequence: this path **entirely sidesteps macOS's CGEvent/Accessibility injection limits** — input is just bytes written to a file descriptor, no synthetic keyboard events, no TCC `kTCCServicePostEvent`, no activate-then-control. Text is crisp by construction, bandwidth is tiny (idle = 0 bytes), no codec artifacts.

---

### 1. Host PTY bridge — exact APIs

#### 1.1 PTY allocation: `forkpty()` vs `openpty()` + `posix_spawn`

There are two routes, both native Darwin (`<util.h>`):

**`forkpty()` — one-call PTY + fork + exec.** `forkpty(&master, NULL, NULL, &winsize)` atomically allocates the PTY pair, calls `fork()`, calls `login_tty()` in the child, and returns the master FD in the parent; the child `execvp()`s the login shell. This is SwiftTerm's production path (`Pty.swift` → `PseudoTerminalHelpers.fork(andExec:)`) — the master FD becomes the single bidirectional I/O channel for the entire terminal ([SwiftTerm/Pty.swift](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Pty.swift)).

> ⚠️ **CORRECTION — "forkpty() is unsafe to call from Swift" (verified):** this claim is **directionally right but overstated**. Quinn (Apple DTS, [forum thread/747499](https://developer.apple.com/forums/thread/747499)) confirms: the real danger is running Swift/ObjC/libdispatch code **in the child process after fork() and before exec()** — the ObjC runtime crash guard (`objc_initializeAfterForkError`, since macOS 10.13) kills the child if a `+initialize` was running on another thread at fork time. **The `forkpty()` call itself, in the parent, is NOT dangerous.** SwiftTerm calls `forkpty()` directly from Swift in production (Secure Shellfish, La Terminal, CodeEdit) without crashes, because it follows the fork-then-exec-immediately pattern: prepare every C string with `strdup()` **before** the fork, then in the child only call `chdir()` + `execve()` + `_exit()` — pure POSIX, no Swift runtime after fork. This issue is **unrelated** to the Swift 5.9/6 concurrency model (actors/async-await); no new API relaxes the constraint. To eliminate the hazard class entirely, use the second route.

**`openpty()` + `posix_spawn` — the workaround Apple recommends.** `openpty(&master, &slave, NULL, &termp, &winp)` allocates the PTY pair **without forking**; the child is launched via `posix_spawn` with a `posix_spawn_file_actions_t` redirecting stdin/stdout/stderr to the slave FD, `POSIX_SPAWN_SETSID` creating a new session, and `login_tty(slave)` called in a pre-spawn configurator. This pattern **never calls fork() from Swift**, eliminating the ObjC runtime lock hazard altogether — it is exactly what LLVM sanitizer_common does ([D65253](https://reviews.llvm.org/D65253)) and the direction SwiftTerm is migrating toward via `swift-subprocess`.

> ✅ **VERIFIED — `POSIX_SPAWN_SETSID` via `preSpawnProcessConfigurator` is a real production API** in `swiftlang/swift-subprocess` (note: the canonical repo is `swiftlang/`, **not** `apple/swift-subprocess`). `PlatformOptions.preSpawnProcessConfigurator` is `public`, unguarded, with a live test (`testSubprocessPlatformOptionsProcessConfiguratorUpdateSpawnAttr`). However, in **current SwiftTerm** the Subprocess path is guarded `#if false //canImport(Subprocess)` (5 places in `LocalProcess.swift`) → **not active yet**; the default is still `startProcessWithForkpty`.

> ✅ **VERIFIED — `posix_openpt()` is NOT "broken" on macOS** (claim refuted). The original claim misattributed the thread (it is actually [thread/734230](https://developer.apple.com/forums/thread/734230), not 688534) and described it wrong. The truth: `posix_openpt()` works fully on macOS 14/15; Apple's `openpty()` **calls `posix_openpt()` internally** (Libc `util/pty.c:78`). The real limitation is **very narrow**: calling `fcntl(masterFd, F_SETFL, O_NONBLOCK)` fails with `EINVAL` **if the slave has not been opened yet** — the fix is to open the slave before setting non-blocking on the master. `openpty()` avoids it because it opens the slave itself.

#### 1.2 Async reads on the master FD: `DispatchIO`

Once you have the master FD, wrap it in `DispatchIO(type: .stream, fileDescriptor: masterFd)`:

```swift
let io = DispatchIO(type: .stream, fileDescriptor: masterFd, queue: readQueue) { err in
    close(masterFd)              // ⚠️ close in the cleanupHandler, NOT in deinit (avoids the EV_VANISHED crash)
}
io.setLimit(lowWater: 1)
io.setLimit(highWater: 131_072)  // 128 KB — absorbs large bursts (cat of a big file)
// chain reads in the completion handler; coalesce on a 4ms timeslice before dispatching to the transport
```

SwiftTerm uses a `pendingChunks` queue with a **4ms timeslice** (`pendingTimeSliceNs = 4_000_000`) to coalesce bursts, `readSize = 128*1024`, compacting once past `pendingChunkFlushThreshold = 32` chunks. Track shell exit without polling via `DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit)` then `waitpid(shellPid, &n, WNOHANG)` ([SwiftTerm/LocalProcess.swift](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/LocalProcess.swift)).

#### 1.3 Resize: `TIOCSWINSZ` + `SIGWINCH`

When the client reports a new size, call `ioctl(masterFd, TIOCSWINSZ, &winsize)` on the master FD; the kernel sends `SIGWINCH` to the foreground process group, and the shell + vim/tmux re-query `TIOCGWINSZ` and reflow. Struct `winsize { ws_col, ws_row, ws_xpixel=0, ws_ypixel=0 }`. On macOS the `TIOCSWINSZ` constant is typed `Int32` (Linux needs a `UInt` cast). This is what SwiftTerm's `setWinSize()` and mosh-server do on receiving a `Resize` action ([SwiftTerm/Pty.swift:119](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Pty.swift), [mosh-server.cc](https://github.com/mobile-shell/mosh/blob/master/src/frontend/mosh-server.cc)). Bandwidth ~0 — resize is a rare control event.

#### 1.4 Login shell setup — required env vars

Set before `execvp` in the child:

| Variable | Value | Reason |
|------|---------|-------|
| `TERM` | `xterm-ghostty` (fallback `xterm-256color` if paste bug #54700 shows up — see [14]) | matches the libghostty client + kitty keyboard |
| `LANG` | `en_US.UTF-8` | **critical** — without it vi/ncurses emit ISO 2022 sequences |
| `COLORTERM` | `truecolor` | true-color terminal |
| `NCURSES_NO_UTF8_ACS` | `1` | forces ncurses to use UTF-8 box-drawing instead of VT100 line-drawing |
| termios `c_iflag` | `\|= IUTF8` | correct backspace-over-multibyte |
| `argv[0]` | prepend `-` (e.g. `-zsh`) | login shell → sources `.zprofile`/`.zshrc` |

Do **NOT** blindly forward `PATH` from the server process. Mirror `LOGNAME/USER/HOME/DISPLAY` from the parent. Reference: `SwiftTerm.Terminal.getEnvironmentVariables()`; mosh additionally does `unset STY` (so GNU screen doesn't think it is nested).

> ✅ **VERIFIED — `IUTF8` exists on Darwin.** XNU `bsd/sys/termios.h:133` defines `IUTF8 = 0x00004000` under the guard `#if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)` → present in any non-strict-POSIX build. Note: the flag only affects **canonical-mode VERASE**; in raw PTY mode (the typical terminal mode) it has no effect — but set it anyway for correctness.

#### 1.5 App Sandbox — an architecture decision, not a runtime one

A sandboxed app **cannot** `forkpty()`/`execvp()` an arbitrary shell — the sandbox blocks exec of processes not declared in entitlements, and **no entitlement** whitelists an arbitrary shell. Apple-accepted patterns:

1. **A non-sandboxed app distributed via Developer ID** (outside the Mac App Store) — standard for dev tools (Xcode, VS Code, iTerm2, Terminal.app are all **not** sandboxed). **Recommended for the host component.**
2. A non-sandboxed LaunchDaemon/LaunchAgent helper, talking to the sandboxed app over XPC or a local socket.
3. A privileged helper via `SMJobBless`/`SMAppService`.

Conclusion: **the host component must be non-sandboxed**. Mac App Store distribution is **incompatible** with arbitrary shell spawning via `forkpty`. Enable **Hardened Runtime** (`codesign -o runtime`) on the helper to block dylib injection (`DYLD_INSERT_LIBRARIES`); the PTY-spawning helper needs **no** special entitlement — but must **not** add `com.apple.security.cs.disable-library-validation`. Run the shell **as the logged-in user, not root**; pin the shell binary (`$SHELL` from `/etc/passwd`), and **never let the client specify** path/env (lesson from ET CVE GHSA-hxg8-4r3q-p9rv: a client-supplied path reaching a privileged file op → escalation).

---

### 2. Transport — choose reliable TCP, not mosh-SSP UDP

This is a key architectural decision and the corpus is unambiguous: **on LAN, use a plain TCP byte relay over Network.framework. Do NOT port mosh SSP.**

| | TCP byte relay (ET-style) | mosh SSP (UDP state-sync) |
|--|---------------------------|---------------------------|
| Unit | raw PTY bytes verbatim | terminal **state diff** (framebuffer) |
| Loss tolerance | TCP handles it (LAN loss ~0) | idempotent datagrams, tolerates loss |
| Crypto | TLS 1.3 (CryptoKit/Security) ready-made | **AES-128-OCB3** |
| Server emulator | **not needed** (stateless relay) | **must run a full emulator** (`Terminal::Complete`) |
| Code | minimal | complex (state machine, fragmentation, fec) |
| Fit | **LAN <1ms RTT** | lossy WAN |

The decisive reason: on LAN, typical RTT is **<1ms** with loss <0.01% → TCP head-of-line blocking is **insignificant**, mosh-style frame-skipping **buys nothing** over raw TCP streaming, while the implementation complexity is far higher. Mosh SSP is optimized for a 29% packet-loss link (SSH 16.8s → SSP 0.33s, 50× — [mosh paper](https://mosh.org/mosh-paper.pdf)) — a situation that **does not exist** on wired LAN.

> ⚠️ **CORRECTION — AES-128-OCB is not in CryptoKit** (verified, confirmed). If for some reason you wanted to port SSP, know that CryptoKit exposes **only** `AES.GCM` and `ChaChaPoly`, with **no** `AES.OCB`. CommonCrypto does **not** expose OCB as a mode either (no `kCCModeOCB`). Three options: (1) port mosh's `ocb_internal.cc` using CommonCrypto purely as the raw AES block-cipher backend (exactly how mosh builds on macOS), (2) link a separate OpenSSL and use `EVP_aes_128_ocb()`, or (3) replace OCB with AES-GCM + native CryptoKit, accepting a wire format different from mosh. Since we do **not** use SSP, this is only a warning — use native **TLS 1.3 / AES-GCM** over TCP.

#### Wire protocol — type-prefix framing (ttyd-style)

Simplest for LAN, and lets resize ride alongside data:

```
[1-byte type] [4-byte big-endian length] [raw payload]
  type 0 = terminal data (raw PTY bytes verbatim)
  type 1 = resize {cols, rows}
```

ttyd uses exactly this pattern: server→client `'0'`=OUTPUT, client→server `'0'`=INPUT, `'1'`=RESIZE ([ttyd/protocol.c](https://github.com/tsl0922/ttyd/blob/main/src/protocol.c)). **No JSON on the hot path** (terminal bytes). Transport is `NWConnection(.tcp)`: `NWListener` on the host, `NWConnection` on the client; manual 4-byte length framing or `NWProtocolFramer`. The SSH RFC 4254 channel model (multiplexing, flow-control windows) is **overkill** for LAN one-connection-per-session — borrow only the `window-change` payload structure (cols/rows uint32) if needed ([RFC 4254](https://datatracker.ietf.org/doc/html/rfc4254)).

> 📋 **Claim to verify during implementation:** `NWProtocolFramer` handles arbitrary byte sequences (not treated as text) and has no min-MTU constraint fragmenting small keystrokes. Test before locking in.

Natural idle efficiency: the master FD **produces no bytes while the shell is idle** → 0 bytes flow, no encode/decode. This is the most important performance lever for a coding tool (the screen is static most of the time).

---

### 3. Mosh-style predictive local echo — ⏸️ DEFERRED (assume P2P)

> ⏸️ **DEFERRED for v1** (final decision: assume NetBird direct P2P ~1–5ms, drop prediction — see [13 §4], Phase 5). The analysis below is kept as **reference** in case relays become common later.
>
> 🔎 **Update (see [17 §2.4]):** the reasons *not* to build a full predictor go beyond low RTT: (1) `ghostty_surface_t` is opaque → it would force a **second VT parser** maintaining a shadow framebuffer (desync risk); (2) **the Claude Code TUI uses the alt-screen** → Mosh disables prediction there anyway, so the benefit shrinks to the bare shell prompt. The cheap Phase 2 substitute = a **glitch-window caret** (track only the cursor column, no shadow parser).

This is the most port-worthy technique in mosh, **independent of transport**. The engine predicts the result of a keystroke and renders it **instantly** (before the packet leaves the NIC), `underline`s unconfirmed characters, and self-corrects when the real server state arrives. Original evaluation (USENIX ATC 2012, 40h / 9,986 keystrokes): **70% of keystrokes displayed instantly** with confident prediction, only **0.9%** needed within-RTT correction.

#### The engine is portable logic, not OS-dependent

> ✅ **VERIFIED — PredictionEngine fully transport-agnostic.** `terminaloverlay.cc` does **not** include any `Network::` class. The engine needs only **4 values** injected via plain setters: `local_frame_sent`, `local_frame_acked`, `local_frame_late_acked` (echo_ack from remote state), `send_interval` (= `ceil(SRTT/2)` clamped `[20,250]`ms). nosshtradamus (thyth/nosshtradamus) proved the engine runs over **TCP/SSH** using a side-band ping to reconstruct those 4 variables. Meaning: with our TCP byte stream, just maintain an epoch counter + RTT estimate → the engine runs unmodified.

Core mechanics (`terminaloverlay.h/.cc`):
- **`new_user_byte(byte)`**: a printable ASCII character (0x20–0x7e, width 1) → advance the predicted cursor, store a `ConditionalOverlayCell` at `(row,col)`, tagged with the current `prediction_epoch`.
- **`apply(server_fb)`**: layer the overlay onto the server framebuffer before computing the display diff.
- **Backspace (0x7f)**: decrement cursor.col, shift the line left (each cell = the cell to its right), the rightmost cell marked `unknown=true` (renders underlined).
- **Epoch self-correction**: when the server-confirmed state differs from the prediction, call `kill_epoch(tentative_until_epoch)` → discard every tentative prediction of that epoch; `become_tentative()` increments `prediction_epoch`. A misprediction only kills the current epoch; older confirmed predictions stay. **Control chars (arrows, Escape) also call `become_tentative()`** because they cannot be predicted.
- **Paste suppression**: if `bytes_read > 100` (bulk paste) → `reset()` all predictions (avoids flicker while the shell/readline re-wraps).

#### ⚠️ The decisive CORRECTION for LAN: use `DisplayPreference = Always`

> ✅ **VERIFIED (confirmed) — On LAN, Adaptive mode yields ZERO local echo.** In `cull()`, `srtt_trigger` only flips `true` when `send_interval > SRTT_TRIGGER_HIGH=30ms` (strict). And `send_interval = max(ceil(SRTT/2), 20)` → for **any SRTT < ~40ms**, `send_interval = 20ms`, which is **not** > 30 → the trigger stays silent. With `display_preference == Adaptive`, `apply()` renders when `srtt_trigger || glitch_trigger`; both false → **renders nothing**. The trigger only fires at SRTT ≥ ~61ms. **Conclusion:** on direct LAN (1–5ms) prediction is nearly useless → **DEFER**. IF relays become common later, enable it then with `DisplayPreference=Always`.

Reference constants (verified): `SRTT_TRIGGER_HIGH=30`, `SRTT_TRIGGER_LOW=20`, `FLAG_TRIGGER_HIGH=80`, `FLAG_TRIGGER_LOW=50`, `GLITCH_THRESHOLD=250ms`, `GLITCH_FLAG_THRESHOLD=5000ms`, `SEND_MINDELAY=8ms` (the client sets `set_send_delay(1)`=1ms), `SEND_INTERVAL_MIN=20ms`, paste suppression `>100` bytes.

#### Two implementation options

The `terminaloverlay.cc` engine is ~750 lines of C++. Two routes: (a) **CGo/C interop** (as nosshtradamus does with go-mosh) — reuse battle-tested code; (b) **a pure Swift port** — cleaner for a native app, avoids the C bridge. The corpus found no existing Swift port → this is real implementation work. **Note:** because libghostty is opaque (no cell-grid access), the full engine needs its own client-side shadow VT parser — exactly why we do **not** build it for v1 ([17 §2.4]). If Phase 2 needs it, this is the integration point.

---

### 4. Client renderer — libghostty (only)

Renderer = **libghostty full surface**; the decision + external-backend patch recipe live in §3.1 "Client renderer — libghostty". **Do NOT use SwiftTerm** (best-only philosophy, no fallback). Wiring: `ghostty_surface_feed_data` ← network bytes; write-callback (`use_custom_io`) → PTY stdin; wrap behind a `TerminalRendering` protocol to isolate the C-ABI. (SwiftTerm `Pty.swift`/`LocalProcess.swift` remain only as a *citation* for the POSIX PTY pattern in Part B §1, not a dependency.)

### 5. Resize / encoding / scrollback

- **Resize**: client `sizeChanged` delegate → message type 1 → host `ioctl(masterFd, TIOCSWINSZ, &winsize)` → `SIGWINCH` (§1.3). Zero bandwidth.
- **Encoding**: UTF-8 end-to-end. `LANG=en_US.UTF-8` + `IUTF8` + `NCURSES_NO_UTF8_ACS=1` (§1.4). libghostty handles grapheme clusters/emoji on the client.
- **Scrollback**: **client-side only**. A raw PTY has **no scrollback** — bytes once read are gone from the OS buffer. The libghostty surface keeps scrollback internally (configured via the surface config). **The server is a stateless byte relay** → zero cost. Optional: the server keeps an **ET-style seq replay buffer** (§6, [17 §2.3]) for reconnect.

---

### 6. Reconnect / roaming

#### ET-style packet-framed buffering — the right way

Eternal Terminal's `BackedWriter`/`BackedReader` is the direct prior art: buffer **complete packets** tagged with a `sequenceNumber` (deque, capped at `MAX_BACKUP_BYTES = 64MB`). Reconnect: the client sends its reader `sequenceNumber` in a `SequenceHeader` protobuf → the server's `recover(lastValidSeq)` computes how many packets to retransmit → packs a `CatchupBuffer` → both sides `revive(newFd)`. **The unit is a complete packet, not a raw byte slice** → replay always starts on a packet boundary, **structurally eliminating the mid-escape-sequence truncation hazard** ([BackedWriter.cpp](https://github.com/MisterTea/EternalTerminal/blob/master/src/base/BackedWriter.cpp), [Connection.cpp:96-141](https://github.com/MisterTea/EternalTerminal/blob/master/src/base/Connection.cpp)). Reconnect overhead: ~1 RTT for the sequence exchange.

> ⚠️ **A data-loss boundary to handle:** ET `DISCONNECT_BUFFER_BYTES = 4MB` — while disconnected, once the buffer exceeds 4MB, `write()` returns `SKIPPED` (new output is dropped). For long builds running while the client is offline, output can be lost. Consider raising the disconnect buffer (bounded by RAM) for the coding use-case.

#### Fallback raw-byte path: DECSTR prefix

> We use **ET packet-framed buffering** (above) as the main path — this is only a technical note for the raw-byte replay case.

If you do **not** use packet framing and instead replay raw VT bytes from a ring buffer, **feed `ESC [ ! p` (DECSTR, Soft Terminal Reset) into `ghostty_surface_feed_data` before replaying the tail**. DECSTR resets cursor visibility, insert/origin/autowrap modes, G0–G3, SGR, cursor home, scroll margins — exactly the modal state that gets corrupted by a mid-sequence replay. (Opaque libghostty has no dedicated `softReset()` function → push the DECSTR bytes themselves into the stream; Ghostty's own VT parser handles them.) DECSTR does **not** fully remove the hazard if an escape sequence straddles the wrap point → combine with a **sync-point marker** (the host periodically emits a no-op DCS; the client scans for the last marker and discards everything before it). Since the main path is packet-framed (replay starts on packet boundaries), this hazard **never arises** — which is why ET-style was chosen.

#### Persistent PTY — survives every disconnect

The PTY/shell must live independently of the TCP connection: a **helper process holds the master FD**, not a per-client connection handler. Because the helper owns the master FD, closing the client socket does **not** cause the kernel to send `SIGHUP` to the shell's process group. Two ways: (a) a **persistent host daemon** (launchd `KeepAlive=true`) holding `[UUID: PTYSession]`; (b) **tmux** (v2 upgrade) — the server process holds every master FD, sessions live indefinitely, reconnect = `tmux -CC attach`, and you also get server-side scrollback + window/pane mapping for free (iTerm2's `TmuxGateway.m`, ~884 lines, is the reference). Add a configurable idle-kill timer (e.g. 48h) to avoid accumulating orphaned shells.

#### iOS lifecycle + roaming

- **iOS background**: ~30s budget (`beginBackgroundTask`); sockets are reclaimed by the OS on suspend (TN2277). **Do NOT try to keep the socket alive across suspension.** The right pattern: scenePhase `.background` → `connection.cancel()` + mark disconnected; scenePhase `.active` → create a new `NWConnection` + ET sequence-exchange resume. For a brief network gap (no app lifecycle event) → rely on the `NWConnection` `.waiting` state with `waitingForConnectivity` auto-advancing to `.ready`.
- **macOS host wake**: lid-close **forces sleep regardless of** `IOPMAssertion` type. Subscribe to **`NSWorkspaceDidWakeNotification`** (the NSWorkspace notification center, not defaultCenter) → re-listen the `NWListener`, check `NWPathMonitor` before accepting. `NSActivityUserInitiated` blocks App Nap + idle sleep but does **not** block lid-close sleep. (📋 Verify: whether a non-GUI launchd KeepAlive daemon reliably receives `NSWorkspace` notifications — needs a running CFRunLoop.)
- **macOS client Wi-Fi↔Ethernet roaming**: `NWPathMonitor.pathUpdateHandler` fires on dock/undock; `NWConnection.viabilityUpdateHandler(false)` is the signal to cancel + create a new connection + sequence exchange. Because the `BackedWriter` buffer persists in-process (not tied to a socket), catchup delivers the buffered output right after 1 RTT.

---

### Recommendation summary (implementation-ready)

| Item | Decision |
|----------|-----------|
| PTY allocation | `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()` (avoids the fork-in-Swift hazard); or `forkpty()` with strict fork-then-exec-immediately |
| Async I/O | `DispatchIO(.stream)` lowWater=1, highWater=128KB, close in the cleanupHandler |
| Resize | `ioctl(TIOCSWINSZ)` → SIGWINCH |
| Sandbox | host **non-sandboxed** Developer ID, Hardened Runtime, runs as the logged-in user |
| Transport | **TCP** over Network.framework, type-prefix framing (ttyd-style), **no app-layer TLS** (WireGuard encrypts, [13]). **NO mosh SSP/UDP** |
| Local echo | ⏸️ DEFERRED (assume P2P; revisit only if relayed) |
| Client emulator | **libghostty** full surface (self-owned patch, Metal GPU, ligatures OK) — **no SwiftTerm** |
| Scrollback | client-side (the libghostty surface keeps scrollback internally); stateless server + ET-style seq replay buffer for reconnect ([17 §2.3]) |
| Reconnect | ET packet-framed sequence buffer (64MB cap; mind the 4MB disconnect SKIPPED); persistent PTY helper (v1) → tmux `-CC` (v2) |
| iOS/roaming | eager reconnect on scenePhase `.active`; `NWPathMonitor` + `NSWorkspaceDidWakeNotification` |

Primary sources: [SwiftTerm Pty.swift / LocalProcess.swift / Terminal.swift / AppleTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm), [mosh terminaloverlay.cc / transportsender-impl.h / network.cc](https://github.com/mobile-shell/mosh), [Eternal Terminal BackedWriter/BackedReader/Connection](https://github.com/MisterTea/EternalTerminal), [ttyd protocol.c](https://github.com/tsl0922/ttyd), [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess), [nosshtradamus](https://github.com/thyth/nosshtradamus), Apple [Network.framework](https://developer.apple.com/documentation/network/nwconnection) / [forum thread 747499](https://developer.apple.com/forums/thread/747499) / [thread 734230](https://developer.apple.com/forums/thread/734230), XNU `bsd/sys/termios.h`.

---

## GUI video path (4:2:0 is good enough) — simplified

> Re-scope: the "text crispness" requirement has been **dropped** for the video path. Every GUI window (VS Code, Xcode, browser...) goes through **ScreenCaptureKit → VideoToolbox HEVC 4:2:0 → Network.framework → decode → Metal**. The terminal path (PTY text) carries all of the most demanding text, so the video codec no longer has to strain for text. This document replaces the "optimize motion-to-photon < 16ms" mindset of the earlier docs with an **idle-efficiency + encode-on-change** mindset for a mostly static screen.

---

### TL;DR (GUI video path)

- **4:2:0 HEVC is good enough** for reading code in a GUI window. Luma (Y) keeps full resolution → glyph edges stay sharp; only chroma (Cb/Cr) is subsampled → slight color fringing at harsh color boundaries. With a dark theme (light text on a dark background) the fringing is even less visible. (`claim_to_verify`: "tolerable" is a subjective judgment; must be user-tested at the actual target resolution/bitrate — see §6.)
- **4:4:4 is dropped outright**, and not out of laziness: **Apple's HW encoder has no 4:4:4 for HEVC**. The complete set of `kVTProfileLevel_HEVC_*` in the SDK (through iOS/visionOS 26, 2025) is only Main / Main10 / Main42210 / Monochrome / Monochrome10 — **no** SCC or 4:4:4 streaming profile exists. Switching codecs cannot fix it; this is a hardware limit, not a configuration choice.
- **The levers that ACTUALLY matter now are about idle-efficiency**, not latency: `SCFrameStatus.idle` (zero encode when static) + `dirtyRects` (encode changed regions) + `minimumFrameInterval` capped at **~24–30 fps** (sufficient; cuts bandwidth/latency/CPU) + CQ. A code screen sits still most of the time → average bitrate approaches 0 when idle, bursting only on typing/scrolling/compiling.

---

### 1. Why 4:2:0 is good enough (and 4:4:4 is dropped)

### 1.1 Mechanism: luma stays sharp, only chroma is subsampled

ScreenCaptureKit captures frames as `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) — the CPU-cheapest pixel format for VideoToolbox HEVC. 4:2:0 only reduces chroma resolution, both horizontally and vertically; **the luma channel remains full resolution**, and glyph edges (light/dark contrast) live mostly in luma. Consequences:

- White/gray text on a dark background (VS Code Dark+, Xcode dark): virtually no visible harm — edges are decided by luma.
- Colored text on a harshly colored background (red/green syntax highlighting on a light background): slight chroma fringing, "softer" than the local display but still comfortable to read for daily coding.

Sources: ScreenCaptureKit pixel-format guidance (WWDC22 10155); screen-sharing codec comparison (Microsoft Azure Virtual Desktop graphics-encoding docs).

### 1.2 4:4:4 is dropped because of hardware, not because of the re-scope

This point needs to be explicit so nobody later tries to "turn 4:4:4 back on for sharpness":

- **Verified (confidence: high):** the complete list of `kVTProfileLevel_HEVC_*` in `VTCompressionProperties.h` across every SDK from macOS 10.13 / iOS 11 through iOS/visionOS 26 (2025) contains only `Main_AutoLevel` (8-bit 4:2:0), `Main10_AutoLevel` (10-bit 4:2:0), `Main42210_AutoLevel` (10-bit 4:2:2), `Monochrome`, `Monochrome10`. There is **no** `kVTProfileLevel_HEVC_SCC_*` or any 4:4:4 variant. FFmpeg's `videotoolboxenc.c` also loads exactly those three encoder-facing HEVC symbols. (Sources: VTCompressionProperties.h in xybp888/iOS-SDKs; FFmpeg videotoolboxenc.c lines 122-197.)
- **HEVC-SCC (palette mode, intra block copy) is also absent** from VideoToolbox — the screen-content-specific tools sit outside both the API surface and (by inference) the hardware block. Competitors like Parsec/Moonlight treat 4:4:4 as the #1 lever for UI/text, but they can enable it thanks to Intel/Nvidia 4:4:4 HW encode — something Apple does not have.

→ Since the terminal path already carries the most demanding text, **accepting 4:2:0 for the GUI is the right architectural decision**, not a reluctant compromise.

---

### 2. Lever #1 — `SCFrameStatus.idle`: zero encode when static

Every `CMSampleBuffer` ScreenCaptureKit delivers carries an `SCStreamFrameInfo` attachment; the `.status` key returns an `SCFrameStatus`. WWDC22 (session 10156) says verbatim: *"An idle frame status means the video sample hasn't changed, so there's no new IOSurface."*

The mandatory pattern — guard **before** submitting to the encode queue:

```swift
guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, ...),
      let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
      SCFrameStatus(rawValue: statusRaw) == .complete else {
    return   // .idle / .blank / .suspended → drop, do NOT encode
}
// only .complete carries a new IOSurface → submit to VTCompressionSessionEncodeFrame
```

**Important caveats (verdict: uncertain, confidence: medium):**
- "No new IOSurface" is Apple-confirmed. But **"zero GPU work / zero encode" is NOT an OS property** — ScreenCaptureKit does not encode anything itself; encoding is the app's job. Idle = zero encode **only if** the app applies the `status == .complete` guard before every VideoToolbox call. This is exactly the pattern Apple's sample code recommends.
- The callback **still fires** for idle frames (evidence: Apple's sample code uses `guard status == .complete else { return }`; OBS routes every callback unconditionally and only then nil-checks the IOSurface). So **do not assume** the encode thread auto-sleeps when idle — if you want to sleep the encode thread to save battery, manage it yourself based on how long it has been since the last `.complete` (`open_question`: does the idle callback rate follow `minimumFrameInterval` or get suppressed entirely — Apple forum thread/718356 is unclear).

Impact: while reading/thinking/debugging, the screen sits still for seconds at a time → encode+transmit bitrate **drops to 0** naturally, because the OS signals idle directly — no timers/polling needed.

---

### 3. Lever #2 — `dirtyRects`: region-based encode-on-change

`SCStreamFrameInfo.dirtyRects` (key `.dirtyRects`) returns `[CGRect]` in content coordinates covering exactly the regions that changed since the previous frame (cursor blink, one line of code, a gutter scroll...). WWDC22 (10155) recommends it directly: *"use dirty rects to only encode and transmit the regions with new updates, and copy the updates onto the previous frame on the receiver side."*

Two patterns; choose by acceptable complexity:

| Pattern | How | Assessment |
|---------|----------|----------|
| **A — full-frame + attached dirtyRects** | Still encode the full frame with VideoToolbox, but send the dirtyRects list along so the receiver composites only the changed regions onto its cached previous frame | Simple, fits VideoToolbox (whole-frame encode). Recommended for v1. |
| **B — crop-encode only the dirty regions** | Encode/transmit tiles of the changed regions | Needs tiling / macroblock-level control that VideoToolbox does not expose → complex. Postponed. |

Impact: when only one pane changes (an autocomplete popup, build-output scroll while another pane is static), the payload drops sharply. Combined with idle-skip → the session-average bitrate sits far below peak.

`open_question`: what fraction of a frame is actually dirty in a real coding session (autocomplete, cursor blink, scroll) — this decides whether pattern B is worth doing over full-frame VBR. Needs real measurement.

---

### 4. Lever #3 — variable / low fps

`SCStreamConfiguration.minimumFrameInterval` (CMTime) caps the frame delivery rate. **Decision: cap at ~24–30 fps** (smooth enough for scrolling/typing, cuts bandwidth/latency/CPU vs 60fps). (Apple's WWDC22 10156 even suggests 10fps for very static text — we pick 24–30 for smoother scrolling.)

```swift
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // cap ~30 fps; idle-skip keeps near-zero when static
config.queueDepth = 3                                            // true default=8; use 2–3 for low latency ([11]); releases surfaces fast
config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12 4:2:0
```

- The two mechanisms complement each other: **idle-skip** handles static periods; **minimumFrameInterval** caps the rate during motion.
- For coding, **24–30 fps** is the balance point (smooth scrolling at ~half the bandwidth/CPU of 60fps). Cap 30 + idle-skip = ≤30 encodes/second when active, **0 at rest**.
- `queueDepth`: a frame must be processed + released within `minimumFrameInterval × (queueDepth − 1)` seconds to avoid dropped frames. On `.idle` return immediately without holding the surface; on `.complete` submit, then release once the encoder has consumed the pixels (VideoToolbox retains internally).

---

### 5. VideoToolbox configuration for static screens

Keep the pipeline on the Apple Silicon Media Engine (HEVC encode runs off the P/E CPU cores → low battery/heat, true to the spirit of a laptop coding tool):

```swift
// Encoder spec
kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = kCFBooleanTrue

// Properties
kVTCompressionPropertyKey_ProfileLevel       = kVTProfileLevel_HEVC_Main_AutoLevel   // 4:2:0, auto level
kVTCompressionPropertyKey_RealTime           = kCFBooleanTrue
kVTCompressionPropertyKey_AllowFrameReordering = kCFBooleanFalse                      // P-frames only, no B-frames, no lookahead bubble
kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration = 2.0                           // an I-frame every ~2s for error repair, without keyframe bloat
```

**Choose the rate-control mode by environment:**

- **LAN (the default for this tool): constant quality** — `kVTCompressionPropertyKey_Quality = 0.6`. Easier to tune than bitrate+DataRateLimits: static frames produce tiny NALUs, and bursts (compile/scroll) take all the bits they need. On LAN bandwidth is not the bottleneck, so CQ is the natural fit for "near-zero when idle, enough bits when active".
  - **Verified (confidence: medium):** CQ exists only on **Apple Silicon (macOS ARM64)**, not on Intel/T2. FFmpeg gates it with `!TARGET_OS_IPHONE && TARGET_CPU_ARM64` and the comment "constant quality only on Macs with Apple Silicon". Apple does **not** document this key per-chip → **feature-detect / test in practice**, with a fallback to bitrate mode for Intel hosts.
- **WAN / constrained bandwidth (if expanded later):** `AverageBitRate` + `DataRateLimits` (CFArray `[peak_bytes, duration_seconds]` for bursts).

**Low-latency rate control with HEVC (verdict: uncertain — do not treat it as guaranteed):**
- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` **has empirical evidence of working with HEVC on Apple Silicon** (FFmpeg patch merged, commit d87210745e, 9/2025, gated `TARGET_CPU_ARM64`) — but **Apple has not documented** HEVC for this key; WWDC21 says "supported video codec type in this mode is H.264". The header only declares the symbol available since macOS 11.3 with no codec constraint, and does not confirm HEVC either.
- → Under this re-scope, low-latency mode is **no longer a goal**: fps is not a goal, motion-to-photon < 16ms was dropped. It can be enabled for HEVC-on-Apple-Silicon if testing shows it is fine, but it is **no longer a load-bearing feature**. `AllowFrameReordering=false` (eliminating B-frames) already suffices for the needed input responsiveness.

`claim_to_verify`: does `kVTCompressionPropertyKey_AllowTemporalCompression=false` (disabling inter-frame) for HEVC make VideoToolbox fall back to software encode — WWDC21 demonstrates the pattern for H.264; unverified for HEVC. Use only if every frame truly must be encoded independently.

---

### 6. Minimum quality bar for reading code

`open_question` with no hard numbers from the sources — this is a framework inferred from HEVC VBR/CQ behavior; it **must be user-tested at the actual target configuration**:

- **Resolution:** capture per-window at the window's **backing resolution** (`width/height = logical size × NSScreen.scaleFactor`), don't hardcode 2×. Capturing at full retina scale → more chroma pixels per glyph → 4:2:0 hurts less. Capture exactly 1 window (`SCContentFilter(desktopIndependentWindow:)`), not the full desktop: a 1920×1080 window on a 2560×1440 display already cuts ~44% of the pixels to encode.
- **Bitrate (estimate, derived — not Apple-measured numbers):** HEVC 4:2:0 1080p VBR for a static code window ~ **0–50 kbps when idle**, **~500 kbps–2 Mbps during active typing/scrolling**. With CQ, bitrate tracks content complexity automatically; no ceiling needed on LAN.
- **Open question to measure:** the minimum bitrate at which 12pt code in VS Code Dark+ at 2560×1440 (logical) is still comfortably readable when rendered at 1920×1200 on an iPad? **No number in the sources** — bench it for real.

Reference comparison: HEVC saves ~25–50% bitrate vs H.264 at equivalent quality (Azure Virtual Desktop docs). On Apple Silicon, HEVC 1080p60 encode takes ~18ms/frame, capture overhead ~1.9% of one CPU core at 60fps (Lumen/Sunshine-fork numbers + WWDC22; `claim_to_verify` since these are third-party numbers varying with quality/complexity).

---

### 7. How this differs from the earlier latency-obsessed docs

| Old mindset (10-latency-optimization, 11-absolute-latency) | New mindset (hybrid re-scope) |
|---|---|
| Motion-to-photon < 16ms as the top goal | **Dropped.** The code screen is mostly static; typing/cursor responsiveness is handled by the **PTY/terminal path** (bytes into PTY stdin, no CGEvent needed), not the video path |
| High fps (60/120 ProMotion) | **Cap at ~24–30 fps** (sufficient; cuts bandwidth/latency/CPU); prioritize **idle-efficiency** + encode-on-change |
| 4:4:4 / text sharpness as lever #1 | **4:4:4 dropped outright** (no HW support). Demanding text goes via the terminal path. 4:2:0 is good enough for GUI |
| Low-latency rate control as load-bearing | Demoted to "nice-to-have, uncertain for HEVC". `AllowFrameReordering=false` already suffices |
| Optimize every frame | Optimize for **most frames being idle**: the `SCFrameStatus.idle` guard + `dirtyRects` are the center of gravity |

The invariants kept from the old docs: HW HEVC encode on the Apple Silicon Media Engine (low battery/heat), per-window capture via `SCContentFilter(desktopIndependentWindow:)`, NV12 4:2:0 input, P-frames-only.

---

### 8. Remaining open questions

- Does `SCFrameStatus.idle` deliver callbacks steadily at `minimumFrameInterval`, or are they suppressed entirely? Affects whether the encode thread can sleep (Apple forum thread/718356 is ambiguous).
- Does VideoToolbox HEVC on Apple Silicon expose `kVTCompressionPropertyKey_ConstantBitRate`, or only `AverageBitRate` + `DataRateLimits`? CBR helps network buffering but may hurt idle-efficiency.
- Does HEVC hardware decode on iPad add latency that cancels the encode savings on the Mac side vs H.264? Expected to be very small, but no number in the sources.
- Is 4:2:0 fringing on dark-theme VS Code/Xcode truly "tolerable" at the target resolution/bitrate? **Subjective judgment — user-test required.**

---


---

## Roadmap & docs updates for the hybrid architecture

> This section overrides the phase direction of [07-roadmap.md](07-roadmap.md) and flags the over-engineering in [05](05-input-window-control.md), [09](09-codec-choice.md), [11](11-absolute-latency.md) for the new **hybrid** architecture: **terminal path (PTY byte stream like SSH/mosh, rendered with libghostty)** + **GUI window path (ScreenCaptureKit -> VideoToolbox HEVC 4:2:0)**. Every claim below tracks the verified corpus; wherever the corpus marked something `refuted`/`uncertain`, that is reflected as a correction/uncertainty.

---

### 1. Technique ranking for the hybrid tool (biggest levers -> marginal)

Order = (value delivered for daily coding) × (certainty) ÷ (risk + effort). The "Apple" column = native support level per the corpus.

| # | Technique | Why it wins big | Apple | Difficulty | Risk |
|---|----------|-------------------|-------|-----|--------|
| **1** | **PTY bridge text-path** (`forkpty()`/`openpty()` + DispatchIO + VT byte stream over TCP, client render) | **Entirely sidesteps macOS's input-injection problem**: a keystroke is just bytes written to the PTY master fd — no CGEvent, no Accessibility, no activate-then-control, no TCC. Text crisp **by construction** (no video codec). Near-zero idle (a quiet PTY produces no byte flow). Bandwidth ~36–52 bytes/keystroke. | native | low | low |
| **2** | **libghostty as the client renderer** (full surface + **self-owned external-backend patch**, ref daiimus External.zig; `ghostty_surface_feed_data` ← network, write-callback → host) | Ghostty-class rendering: Metal GPU, highest VT fidelity, Kitty graphics, ligatures. Proven on iOS (VVTerm/Moshi). Price: ~1–3 weeks standing up the Zig build + own patch + vendored XCFramework. Wrapped behind `TerminalRendering` to isolate the C-ABI. **No fallback** (best-only — no SwiftTerm). | native (via self-owned patch) | **high** | medium (ABI-instability tax + self-rebased patch; bus factor avoided) |
| **3** | **TCP stream transport over Network.framework** (`NWConnection`/`NWListener` + 1-byte type + 4-byte big-endian length framing, ttyd-style) | The simplest fit for LAN: RTT <1ms so TCP head-of-line blocking is negligible; perfect idle efficiency (no PTY output → no bytes flow). No need for mosh's SSP/UDP. | native | low | low |
| **4** | **Persistent PTY via a helper process holding the master fd** (launchd agent `KeepAlive`, or tmux) | The shell survives every client disconnect (iPad sleep, lid close, Wi-Fi handoff). Because the master fd belongs to the helper process — not the TCP handler — closing the socket sends no SIGHUP to the shell. | native | medium | medium |
| **5** | **ET-style packet-framed ring buffer + sequence-number ACK catchup** (BackedWriter/BackedReader) | Seamless reconnect after LAN interruptions. **Replay on packet boundaries** structurally eliminates the risk of a replay cutting mid-escape-sequence (emulator corruption). | partial | medium | medium |
| **6** | **iOS eager-reconnect on foreground** (`scenePhase .active` -> new NWConnection + sequence exchange; do **not** try to keep the socket alive across suspension) | Matches iOS reality: the OS reclaims sockets when the app suspends (~30s background budget). Treat reconnect as the normal fast path, not exceptional recovery. | native | medium | medium |
| **7** | **Clipboard sync: OSC 52** for the terminal path (libghostty OSC 52 action callback; SwiftTerm `clipboardCopy`/`clipboardRead` only a *citation* for the mechanism) | Host->client copy is nearly free, riding inside the PTY byte stream. tmux/Neovim can be configured to emit OSC 52 today. | native | low | medium (read = exfiltration, default-deny) |
| **8** | **ScreenCaptureKit per-window + `SCFrameStatus.idle` skip + `dirtyRects`** (GUI video path) | Near-zero bandwidth on a static screen — the most important idle lever for coding. `guard status == .complete` before encode = zero encode work when idle. | native | medium | low |
| **9** | **VideoToolbox HEVC 4:2:0, `AllowFrameReordering=false`, `RealTime=true`, quality-mode** (GUI path) | HW encode on the Media Engine (~0% of a CPU core), P-frames-only (no B-frame lookahead). 4:2:0 is **acceptable** because the text-crispness constraint was dropped. | native | medium | low |
| **10** | **CGEvent/SkyLight input injection** (GUI video path) | Needed only for **GUI windows**, not for the terminal. Retains the full activate-then-control + private SPI complexity. | partial/unsupported | high | **high** (Electron mouse reject, private API, no MAS) |
| **11** | **Mosh SSP + speculative local echo** (PredictionEngine) | **Not needed on LAN.** Adaptive mode's `srtt_trigger` only fires when `send_interval > 30ms`; LAN clamps at 20ms -> local echo **dormant** (verified). Instant echo would require `DisplayPreference=Always`. A marginal lever for LAN. | native (logic) | high | medium |

**Uncertainty/correction notes tracking the corpus:**
- `forkpty()` from Swift is **safe** if the child calls `execve()` immediately (fork-then-exec) and the parent only takes the master fd — the "unsafe to call from Swift" claim has been **refuted** at the call-site level; the real hazard is only running the Swift/ObjC runtime in the child *before* exec ([forums.swift.org/t/51457], [developer.apple.com/forums/thread/747499]). Apple's recommended workaround: `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()` — exactly the path SwiftTerm is migrating to (currently guarded `#if false //canImport(Subprocess)`).
- `posix_openpt()` is **not "broken"** on macOS (claim refuted) — the only real limitation is `fcntl(O_NONBLOCK)` on the master fd failing with EINVAL before the slave is opened; `openpty()` avoids it because it opens the slave itself ([apple-oss Libc/util/pty.c]).
- HEVC + `EnableLowLatencyRateControl` on Apple Silicon: **uncertain/empirical** — confirmed via an FFmpeg patch (`TARGET_CPU_ARM64`, commit d87210745e, 9/2025) but **Apple does not document HEVC** for this property (WWDC21 says H.264 only). Usable, but feature-detect at runtime ([VTCompressionProperties.h]).

---

### 2. "Do first" — bootstrap shortlist

This is the minimal set for a daily-usable tool, with the lowest risk and highest value:

1. **PTY bridge on the host** — `openpty()` + `posix_spawn` (login_tty, `POSIX_SPAWN_SETSID`), set env `TERM=xterm-ghostty`, `LANG=en_US.UTF-8`, `COLORTERM=truecolor`, the `IUTF8` termios flag (confirmed present on Darwin: `IUTF8 = 0x00004000` in XNU `bsd/sys/termios.h`), prepend `-` to argv[0] for a login shell. Read the master fd with `DispatchIO(.stream, lowWater:1, highWater:131072)`.
2. **Resize**: `ioctl(masterFd, TIOCSWINSZ, &winsize)` when the client reports a new size -> the kernel sends SIGWINCH (SwiftTerm `sizeChanged` delegate -> resize message -> host ioctl).
3. **Transport**: `NWConnection`/`NWListener` TCP, 1-byte-type framing (0=terminal data, 1=resize) + 4-byte length. **No app-layer TLS** — WireGuard encrypts; authorization via NetBird ACL ([13]).
4. **Client libghostty** (full surface + **self-owned external-backend patch**, ref daiimus External.zig): `ghostty_surface_feed_data` ← NWConnection receive loop; write-callback (`use_custom_io=true`) -> NWConnection -> host PTY stdin. Build `GhosttyKit.xcframework` (zig), vendor + pin upstream SHA, re-apply the patch on bumps. Wrap behind `TerminalRendering`. **No fallback** (best-only — no SwiftTerm).
5. **Persistent PTY**: the host helper is a launchd agent with `KeepAlive=true` holding all master fds; PTYs survive disconnects.
6. **Minimal reconnect**: iOS `scenePhase .active` -> reconnect; macOS client `NWPathMonitor.pathUpdateHandler` -> reconnect on Wi-Fi↔Ethernet changes.

> ⚠️ **Threading caveat (load-bearing, from a corpus `uncertain` verdict):** `feed(byteArray:)` is documented as "can be invoked from a background thread", **but** `feedPrepare()` mutates `selection.active`/`search.invalidate()` and `queuePendingDisplay()` reads/writes `pendingDisplay: Bool` **without a lock** on the caller's thread -> a real data race. Mitigation: hop to the main queue before calling `feed()` from the network receive loop, or serialize. Stress-test before shipping.

> ℹ️ **Ligatures:** libghostty (Ghostty) handles ligatures correctly via HarfBuzz shaping — no column drift.

---

### 3. How the docs change

#### 3.1. [05-input-window-control.md] — the biggest risk **disappears for the terminal path**

Doc 05 opens with "This is the project's biggest technical risk". With hybrid, **that statement is now true only for the GUI video path**:

- **The terminal path touches no CGEvent/AX/activate-then-control at all.** Input = bytes written to the PTY master fd via `DispatchIO.write`. No TCC Accessibility, no `CGEventPostToPid`, no `AXUIElement`↔`CGWindowID` matching heuristics (the "genuinely fragile" point doc 05 §4 admits itself), no macOS 14 cooperative-activation caveat (doc 05 §4 → "macOS 14+ caveat" — "FAILS when triggered by a timer/network" is exactly the remote-control case). **That entire risk chain vanishes for the bulk of the coding workflow (terminal/Neovim/tmux/git/build).**
- **Consequence for the Phase 0 gate:** the 0.4–0.6 spikes in [07-roadmap.md] (AXRaise on the right window, CGEventPostToPid clicking accurately, measuring the activation rate from a network callback) **are no longer project-blocking gates**. They drop to prerequisites for the **GUI video path (a later phase)**, not survival conditions for the MVP.
- **What to change in doc 05:** add a banner at the top of the file: "Applies to the GUI window path; the terminal path sidesteps injection entirely — see PTY bridge". Keep the technical content (still valid for VS Code/Xcode windows) but lower the risk priority.
- **Electron correction (already reflected in the [05] banner):** keyboard injection via `CGEventPostToPid` IS accepted by Electron/VS Code; only the **mouse** is rejected (needs SkyLight SPI) — test on macOS 14/15.

#### 3.2. [09-codec-choice.md] — the 4:4:4 / text-crispness problem is **dropped outright**

Doc 09's TL;DR currently reads "The real text-quality ceiling is 4:2:0 chroma ... lever #1 ... the thing Apple does not have". With hybrid, **this is no longer the central problem**:

- **Text crispness is no longer priority #1.** All the text that stresses a codec most (terminal, code) **goes via the PTY path rendered by libghostty — absolutely crisp, no codec involved**. Video only serves GUI windows (VS Code/Xcode editor views), where **4:2:0 HEVC is acceptable** (the constraint was relaxed).
- **Over-engineering to mark as DROP in doc 09:**
  - §2 "Available levers" item 3 — **"Software encode 4:4:4 ultra-text tier"**: drop entirely. The 4:4:4 problem is dropped; stop optimizing for it.
  - §2 item 1 — **HEVC 10-bit (Main 10) by default "for sharper edges"**: demote to optional. The corpus confirms VideoToolbox has no HEVC-SCC (palette/intra-block-copy — claim `confirmed`: no `kVTProfileLevel_HEVC_SCC_*` exists in any SDK). For the GUI path, **HEVC Main 8-bit 4:2:0** is enough; 10-bit is a marginal tweak.
  - **New recommendation for the GUI path:** `kVTCompressionPropertyKey_Quality = 0.6` (constant-quality, **Apple Silicon macOS ARM64 only** — FFmpeg `vtenc_qscale_enabled()` gates on `!TARGET_OS_IPHONE && TARGET_CPU_ARM64`, claim `confirmed`) + `pixelFormat = 420YpCbCr8BiPlanarVideoRange` + `minimumFrameInterval = CMTime(1, 30)` (cap ~24–30 fps — sufficient, cuts bandwidth/CPU) instead of optimizing chroma.
- **What to change in doc 09:** rewrite the TL;DR as "the GUI window path uses HEVC 4:2:0 8-bit quality-mode; text-heavy content goes via the PTY path with no codec". Keep the codec comparison (Parsec/Moonlight wanting 4:4:4) as historical context, but note clearly "does not apply to hybrid because text moved to the terminal path".

#### 3.3. [11-absolute-latency.md] + [01 §5 latency budget] — the <16ms floor / 120fps / vsync are **over-engineering**

Doc 11 is the "deepest study (73 agents)" of the **absolute latency floor**: a 10–16ms floor @120fps ProMotion, the two dominant stages being capture-vsync + scanout-vsync, beam-racing, `CAMetalDisplayLink preferredFrameLatency=1`. Doc 01 §5 targets "glass-to-glass ~30–50ms, 60fps". **For the hybrid coding profile, this entire optimization layer is over-engineering to downgrade:**

- **Motion-to-photon <16ms is no longer a goal.** The README already states coding tolerates 40–80ms. Therefore:
  - **DROP**: chasing the 10–14ms floor, the 120fps/ProMotion path (doc 11's budget @120fps; doc 01 §5's "ProMotion 120Hz" note — the README already says "120fps/ProMotion: dropped").
  - **DROP**: beam-racing, `CAMetalDisplayLink preferredFrameLatency=1`, slice/sub-frame pipelining (corpus confirms "Slice / sub-frame pipelining is NOT available through the public VideoToolbox API" — `refuted`, it should have been dropped anyway).
  - **DROP for the terminal path**: the entire concept of a vsync-dominated budget. **Terminal-path latency = network RTT + PTY round-trip (~1–5ms LAN), with NO capture-vsync, no scanout coupling, no encode/decode.** All of doc 11's "compositor capture vsync + scanout vsync are the two incompressible costs" analysis **applies only to the GUI video path**.
  - **fps is not a goal**: the corpus correction "`minimumFrameInterval` on macOS 15+ silently defaults to 1/60" is still worth knowing, but for the GUI path we deliberately set it **LOW** (10fps for text content) instead of pushing 60/120. `(1/fps)×0.9` (OBS PR#11896), not `kCMTimeZero` (refuted).
- **Keep from doc 11 (still valid, low-risk for the GUI path):** `queueDepth`'s true default is 8 (not 3), and `2` is valid for low latency; `AllowOpenGOP` defaults to true -> set `false`; `MaxFrameDelayCount=0`; **disable AWDL/`includePeerToPeer`** (causes 40–336ms spikes — important for GUI video over Wi-Fi); idle-frame skip + dirtyRects.
- **What to change in doc 11:** add the banner "This entire floor analysis applies to the **GUI video path**. The terminal path (the default, Phase 1) has a completely different latency model: dominated by network RTT, no vsync." Demote doc 11 from "central study" to "reference for the later video phase".
- **What to change in doc 01 §5:** split the latency budget into 2 tables: (a) **Terminal path** = keystroke -> PTY -> byte stream -> render, ~1–5ms LAN + optional local echo; (b) **GUI video path** = keep the current 6-stage table but relax the target to 40–80ms and drop the 120fps column.

---

### 4. Revised phased roadmap (overrides [07-roadmap.md])

Invert the order: **the terminal text-path is Phase 1** (simpler + higher value + dodges the hardest injection problem). The GUI video path moves to a later phase.

```
Phase 1 (terminal PTY) ──▶ Phase 2 (persist+reconnect+clipboard) ──▶ Phase 3 (iOS client)
   high value, low risk        makes it "daily usable"                  device expansion
                                                                            │
                                            Phase 4 (GUI video) ◀───────────┘  <- injection risk concentrated here
                                            Phase 5 (security + polish)
```

#### Phase 0 — Spike (focus shifted)
Remove the input-injection gate from its project-blocking position. New spikes:
- [ ] `openpty()` + `posix_spawn(createSession)` spawn a login shell, read the master fd via DispatchIO, echo bytes over TCP — verify the shell runs and vim/tmux render box-drawing correctly (env `LANG`/`IUTF8`). (forkpty-unsafe-from-Swift — resolved.)
- [ ] **libghostty spike:** apply the external-backend patch (ref daiimus External.zig / Lakr233 `0002-host-managed-io.patch`), build the XCFramework, feed a byte stream → render on macOS + an iOS device. Verify: fullscreen/alt-screen works, keys routed through `ghostty_surface_key` (kitty/DECCKM correct), action callbacks (COMMAND_FINISHED/PWD) fire.

> 🔬 **Phase 0 — "must measure on device" SPIKE checklist (gates; cannot be researched):**
> - [ ] **binary size** of `GhosttyKit.xcframework` (Metal renderer) on iOS — acceptable or not.
> - [ ] **OSC 133 shell-integration e2e** over the network (a real host shell emits → action callback fires on the client).
> - [ ] (codec, Phase 4) does `AllowTemporalCompression=false` force HEVC software encode (if so → use `MaxKeyFrameInterval=1` like FFmpeg); is `ConstantBitRate` for HEVC available on the target OS (probe `VTSessionCopySupportedPropertyDictionary`, else fall back to `AverageBitRate`+`DataRateLimits`); does `ForceLTRRefresh` take `kCFBooleanTrue` or `@(1)`.
> - [ ] `mach_timebase` numer/denom on M2/M3/M4 — **always call the API, never hardcode 125/3**.
> - [ ] (codec, Phase 4) minimum bitrate for readable text + whether 4:2:0 fringing is "tolerable" — perceptual test on the target display.
> - [ ] `EnableLowLatencyRateControl` + HEVC + `EnableLTR` runtime feature-detect (`VTCopySupportedPropertyDictionaryForEncoder`).

#### Phase 1 — Terminal MVP (Mac host -> Mac client), **replacing the old "video MVP"**
- [ ] PTY bridge host: spawn the shell, stream bytes, `TIOCSWINSZ` resize.
- [ ] TCP transport framing (1-byte type + 4-byte length) over Network.framework.
- [ ] libghostty client: full surface + **self-owned external-backend patch** (XCFramework build), `feed_data` ← network / write-callback → host, wrapped behind `TerminalRendering`. **No fallback** (best-only).
- [ ] Bonjour discovery: host advertises / client lists (kept from [03]).
- [ ] **Done:** open a host shell on a client Mac, type + run vim/tmux/git smoothly, absolutely crisp text, **not a single line of CGEvent/Accessibility**.

#### Phase 2 — Persistence, reconnect, clipboard
- [ ] Persistent PTY via a launchd agent holding the master fd (survives disconnects).
- [ ] ET-style packet-framed ring buffer + sequence-number catchup (corruption-free reconnect; if keeping a raw-byte ring buffer instead, prefix DECSTR `ESC[!p` before replaying the tail — `Terminal.softReset()`).
- [ ] Reconnect: iOS `scenePhase`, macOS `NWPathMonitor`; host `NSWorkspaceDidWakeNotification` re-listen after sleep.
- [ ] Clipboard OSC 52 (host->client copy free; read default-deny + permission prompt). Client->host paste should use **bracketed paste** (`ESC[200~`...`ESC[201~`) rather than an OSC 52 query, avoiding the ~10s Neovim freeze.
- [ ] **Done:** sessions survive iPad sleep / lid close / Wi-Fi handoff; two-way copy-paste.

#### Phase 3 — iOS / iPadOS client
- [ ] libghostty surface in a UIView (iOS), soft keyboard + hardware keyboard -> PTY bytes (Ghostty supports the Kitty keyboard protocol for Neovim/Helix).
- [ ] iOS clipboard: `UIPasteboard.changedNotification`, export via `UIDocumentPickerViewController(forExporting:asCopy:true)`.
- [ ] **iOS UX (settled): libghostty TUI (same as desktop) + the read-only inspector [16] for a structured view.** Do NOT build SDK-driven panes (B2 dropped). The read-only inspector already provides native cards (tool/subagent/todo) without driving the agent → solves the "raw ANSI on a small screen" problem Happy/Happier raise, without losing TUI fidelity.
- [ ] **Done:** code from an iPad over LAN, full terminal.

#### Phase 4 — GUI video path (pushed back to here — where all the injection risk concentrates)
- [ ] ScreenCaptureKit per-window + idle skip + dirtyRects + HEVC 4:2:0 8-bit quality-mode (new doc 09).
- [ ] VideoToolbox decode + Metal render (target 40–80ms, **no** 120fps/beam-racing — doc 11 demoted).
- [ ] Input injection for GUI windows: activate-then-control + `CGEventPostToPid` (keyboard) + SkyLight SPI (Electron mouse) — **this is the truly "hardest" part of doc 05**, now an opt-in per-window feature, not the foundation.
- [ ] **Done:** "mirror this window" for VS Code/Xcode when GUI is needed.

#### Phase 5 — Security & polish
- [ ] **Security = rely on NetBird (WireGuard mesh), do NOT encrypt at the app layer** — see [13](13-netbird-transport.md). WireGuard already provides E2E encryption + node auth; adding TLS/QUIC-crypto would be **redundant** (double encryption, pointless latency). → **Drop** Network.framework TLS / CryptoKit ECDH at the app layer.
  - **Authorization** uses **NetBird ACL** (deny-by-default, per-port): only open the app port from the client group → the host group. WireGuard authenticates the *node*; the ACL constrains *peer→port*.
  - ⚠️ **The NetBird mesh IS the security boundary** (unlike a bare LAN): PTY=RCE is confined to authorized peers (you control membership). Still worth having: a light app-level device allowlist + per-user auth if multiple users share the machine (NetBird OIDC).
- [ ] File transfer (NWProtocolFramer multiplexed channel, or OSC 1337 for small files).
- [ ] Hardened Runtime + Developer ID + notarization (the host helper **cannot** be sandboxed since it spawns shells — ship outside MAS).
- [ ] ~~Speculative local echo~~ — **NOT needed.** Assume NetBird direct P2P (~5–20ms, loss~0) → terminal = **TCP byte stream + libghostty render, no mosh/SSP, no predictive echo**. SSP's benefits only materialize when relayed, and we are **not engineering for relay** ([13 §4](13-netbird-transport.md)).

**Why the phases were inverted (corpus summary):** the terminal path is (a) simpler than [video+injection] — just a byte stream, sidestepping input injection (the libghostty renderer is a one-time effort); (b) higher value — daily coding is terminal/Neovim/tmux/git/build, exactly what every prior-art tool (Blink, code-server, JetBrains Gateway dropping Projector) converged on: "semantic/text streaming beats pixel streaming"; (c) it dodges the hardest problem — input injection. The GUI video path is the fallback for windows with no semantic alternative, exactly where Phase 4 places it.
