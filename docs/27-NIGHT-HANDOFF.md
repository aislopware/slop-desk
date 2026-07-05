# Night Handoff — 2026-06-05

> **Historical session log (2026-06-05). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

Autonomous overnight session. Branch **`fix/terminal-render-connect-once`** (off `main`), **UNCOMMITTED**. Delivered via 10 sequential "ultracode" workflows, each **hardware-tested on the Mac Studio via cua-computer-use** (driven as a user — screenshots), with a root cause for every fix.

## TL;DR

All 5 reported issues are fixed and hardware-validated. The briefly-deferred item (resize repaint) is **also fixed** — a deep bug, not cosmetic. Two additional latent bugs were found and fixed. Tree builds coherently (5 products + 2 GUI apps); **674 unit tests pass, 0 failures**. Nothing committed. See the **pre-commit checklist** below.

---

## Per-issue status

| # | Issue | Status | Where |
|---|-------|--------|-------|
| 1 | Connect-once (new tab/pane reuses host) | ✅ HW-validated | WorkspaceStore endpoint inheritance |
| 2 | Dead-host timeout + auto-reconnect | ✅ HW-validated | `NWMuxByteLink.withMuxConnectTimeout` (~10s), `ReconnectManager` backoff |
| 3 | GUI video (remote desktop) | ✅ renders end-to-end | SlopDeskVideoHost/Client + §A optimizations |
| 4 | Modern dev-friendly UX | ✅ shipped | per-pane status dots + Cmd-K command palette |
| 5 | Host-side GUI (was CLI-only) | ✅ shipped | new `Apps/HostApp-macOS` menu-bar app |
| 7 | Resize "broken" ("vỡ", char misalignment) | ✅ fixed | resize coalescing + **ctty fix** (below) |

### #1 Connect-once
New tabs/panes auto-inherit the existing host connection and connect immediately — **no host:port re-prompt**. HW-verified: "+ New Tab" → second tab connects to the same host with a clean prompt.

### #2 Dead-host timeout + reconnect
- **Transport-level connect timeout** (`Sources/SlopDeskTransport/Mux/NWMuxByteLink.swift` → `withMuxConnectTimeout`, ~10s) so a dead/unreachable host **fails fast instead of hanging in "connecting" forever**. Implemented without wrapping `client.connect` in a child task group (that path deadlocks).
- **Auto-reconnect** with capped exponential backoff in `ReconnectManager` (new `onProgress`/`onGaveUp` hooks); `ConnectionViewModel.Status` gained `.reconnecting(attempt:nextRetry:)` and `.unreachable`.
- HW-validated via the status dot: killing the host makes the pane dot go **green → reconnecting (orange) → unreachable (red)** within ~12s.

### #3 GUI video — RENDERS on hardware
Host SCStream capture → VideoToolbox **HEVC** encode → UDP mux → client `VTDecompressionSession` HW-decode → Metal NV12 render. HW-validated in the live Aqua session (a real Slack window rendered in the "Slack (remote)" pane; host log "encoded+sent frame #1..990", client "DECODED frame #420 → render"). Healthy after the un-gate refactor: all 4 prior fixes present (encoder `-12900` guard, `NSApplication` CGS init, UDP receive re-arm, HEVC parameter-set send), mux is the sole UDP transport, frames delivered INLINE, **VIDEO-HOST-1 (static-window IDR freeze) already fixed** (`StaticIDRDecider`).
- **Optimizations (research §A):** added `kVTCompressionPropertyKey_MaxAllowedFrameQP` for text sharpness (`EnableLowLatencyRateControl` was already on); FEC (`XORParityFEC`) + a client cursor overlay found already wired on.
- ⚠️ Requires **Screen Recording TCC** granted to the capture binary + a **real unlocked Aqua session** (a detached daemon-context launch hits `CGS_REQUIRE_INIT`).

### #4 Modern client UX
- **Per-pane status dots** in the sidebar + pane header (`Sources/SlopDeskClientUI/Workspace/Views/PaneStatusIndicator.swift`), surfacing the #2 reconnect/timeout states.
- **Cmd-K command palette** (`CommandPaletteView`): fuzzy "Run a command or jump to a tab" — Split Right/Down, Toggle Zoom, Close/Reconnect Pane, New/Close/Rename Tab, Next/Prev Tab, Focus Next/Prev Pane, jump-to-tab. HW-verified.

### #5 Host-side menu-bar GUI
New **`Apps/HostApp-macOS`** target → **`SlopDeskHost.app`** (LSUIElement menu-bar agent, bundle `com.slopdesk.host.macos` pinned for TCC). Runs the host **in-process** (links `SlopDeskHost`, via a new additive `HostServer.onConnectionCountChanged` hook). `MenuBarExtra` popover: Start/Stop + editable port + live client count + **TCC permission checklist** (Screen Recording + Accessibility with deep-links, research §C1) + Quit. Builds green, client app unregressed, serving path proven via harness (real client connected, PTY attached, command ran).
- ⚠️ cua **cannot actuate `MenuBarExtra .window` popover buttons** (not in an enumerable AX window) — verify host-start via the harness/CLI, not a cua GUI click. CLI host default port is **7420** (`HostdArguments`); the apps default to 7779.

### #7 Resize — size convergence + the deep repaint fix
- **Size convergence (the "broken"/"vỡ"/char-misalignment complaint):** latest-wins resize **coalescing** on the client OUT-path + a host-side micro-debounce (`MuxChannelSession`). HW-validated: after a fast drag, `stty size` matches the final window grid, scrollback reflows cleanly, no misalignment. Disproves the "pty uses old console size" hypothesis — the PTY now converges to the final size.
- **Repaint (idle prompt blanked after resize):** initially deferred as cosmetic, then **root-caused and FIXED** — see below.

---

## Two deep bugs found & fixed (beyond the 5 issues)

### A. Host PTY had no controlling terminal → broke SIGWINCH **and** job control (WF10)
The "idle prompt blanks after resize" symptom was a surface effect. The earlier hypothesis (powerlevel10k suppressing `reset-prompt`) was **wrong** — this user runs **starship**. True cause: `PTYProcess.spawn` used `posix_spawn(POSIX_SPAWN_SETSID)` + `dup2(slave→0/1/2)` but **never `TIOCSCTTY`**, so the spawned interactive zsh had **no controlling terminal** (`TTY=??, TPGID=0`). With no ctty, the kernel sends **no SIGWINCH** on `TIOCSWINSZ` → zsh never learns it resized → no prompt reprint. The missing ctty **also silently broke job control** (`^Z`, `^C`, foreground-process-group signaling).
- **Fix:** replaced `posix_spawn` with `fork()` (resolved via `dlsym`, since Swift marks `fork` unavailable) → child runs only raw async-signal-safe syscalls: `login_tty(slave)` (= `setsid` + `ioctl(TIOCSCTTY)` + `dup2`) → `close(master)` → `execve` (argv/envp/path built in the parent pre-fork). `Sources/SlopDeskHost/PTYProcess.swift` (heavily doc-commented).
- New regression test `testInteractiveZshControllingTTYAndSigwinch` (spawns `zsh -i`, sends `TIOCSWINSZ` 80→132, asserts `$COLUMNS` updates).
- HW-verified: resize (grow + shrink) → full starship prompt reprints **with no keystroke**, scrollback intact, CPU low.
- ⚠️ **Core-path change** (every shell now spawns via fork). Re-validated by the final consolidation (all builds + 674 tests green).

### B. Host shutdown `close()` hang on a live child (WF9)
`MuxChannelSession.shutdown()` → `PTYProcess.closeMaster()` → `close(masterFD)` **blocked forever** when the session's interactive shell was still alive and the PTY reader thread was parked in an in-kernel `read()`. Reachable in production from `HostServer.stop()` (SIGINT) and `removeMuxSession()` (peer channel-close / link drop).
- **Fix:** `PTYProcess.forceTerminate()` (SIGKILL) + `waitUntilExited(timeout:step:)`; `shutdown()` now does SIGTERM → bounded grace → SIGKILL fallback → then `closeMaster`, so the reader always unblocks first. No `shutdown()` call site is resume-able, so this can't break connect-once.
- HW sanity: host with an active live session, SIGINT → **exits promptly** (was: would hang). Full `SlopDeskHostTests` 80/80.

---

## Build & run

All builds wrapped (during the night) in a hard-timeout process-group runner; never run bare `swift test` (the HostServer E2E suites deadlock the pool — use `--filter`).

```bash
# CLI products — build each SEPARATELY (a multi-product invocation silently builds only one)
swift build -c release --product slopdesk-hostd        # → .build/release/slopdesk-hostd  (terminal host; --port, default 7420)
swift build -c release --product slopdesk-videohostd   # → GUI-video host
swift build -c release --product slopdesk-client       # → CLI terminal client

# Client GUI app (SlopDesk.app) — needs the libghostty-wired project.yml (renderer-ENABLED, intentional)
xcodegen generate --spec Apps/ClientApp-macOS/project.yml
xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj -scheme ClientApp-macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .work/macos-verify/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
# → .work/macos-verify/DerivedData/Build/Products/Debug/SlopDesk.app

# Host menu-bar GUI app (SlopDeskHost.app) — NEW this session
xcodegen generate --spec Apps/HostApp-macOS/project.yml
xcodebuild -scheme HostApp-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .work/host-verify/DerivedData CODE_SIGNING_ALLOWED=NO build
# → SlopDeskHost.app  (menu-bar agent; Start/Stop host + TCC checklist)

# Run (terminal): start host, then launch the client GUI binary DIRECTLY (not `open` — it drops env vars)
./.build/release/slopdesk-hostd --port 7779 &
SLOPDESK_AUTOCONNECT_HOST=127.0.0.1 SLOPDESK_AUTOCONNECT_PORT=7779 \
  .work/macos-verify/DerivedData/Build/Products/Debug/SlopDesk.app/Contents/MacOS/SlopDesk

# Video: needs Screen Recording TCC granted + a real unlocked Aqua session (else CGS_REQUIRE_INIT).
#   Seams: SLOPDESK_VIDEO_AUTOCONNECT=1, SLOPDESK_VIDEO_DEBUG=1
```

Debug seams left ON: `SLOPDESK_RENDER_DEBUG=1` (terminal render log), `SLOPDESK_VIDEO_DEBUG=1`, `SLOPDESK_SHELL_INTEGRATION=0` (opt out of the zsh shim).

## Tests
674 across 6 filtered suites, 0 failures: `SlopDeskClientUITests` 294, `SlopDeskHostTests.PTYProcessTests` 13, `ShellIntegrationTests` 11, `SlopDeskVideoProtocolTests` 86, `SlopDeskVideoHostTests` 161, `SlopDeskVideoClientTests` 109. (Full `SlopDeskHostTests` is 80.) Always `swift test --filter <Specific>`; nothing that constructs a `HostServer`.

---

## Pre-commit checklist (when you decide to commit)

1. **Debug logging** — `SLOPDESK_RENDER_DEBUG`/`rdbg` (GhosttyTerminalView.swift etc.) and `SLOPDESK_VIDEO_DEBUG` are still wired. Env-gated (silent by default), but consider gating/trimming the noisier `[RDBG]`/`[CONN]` lines.
2. **`Apps/ClientApp-macOS/project.yml`** — currently renderer-ENABLED (+39 lines vs HEAD; the libghostty PATH-1 wiring). Required to build the GUI with the Metal renderer. Decide whether to commit the enabled spec or restore the committed placeholder + document the enable step.
3. **WF4 `ShellIntegration` shim** — now somewhat redundant given the ctty fix (default zsh redraws on SIGWINCH once ctty is correct), but **harmless belt-and-suspenders** (its `TRAPWINCH` forces `zle reset-prompt`; for starship, which has no own TRAPWINCH, it guarantees the reprint). Keep, or drop for minimalism (opt-out is `SLOPDESK_SHELL_INTEGRATION=0`).
4. **Untracked artifacts** — `.work/` (build/DerivedData), the xcodegen-generated `.xcodeproj` files (gitignored), `skills-lock.json`. Don't commit `.work/`.
5. **Branch** — `fix/terminal-render-connect-once` carries ~20+ changed/new files across SlopDeskHost, SlopDeskTransport, SlopDeskClient(UI), SlopDeskVideoHost, and the two app targets. Large but coherent; consider splitting into reviewable commits per issue.

## Known caveats / environment
- A couple of `xctest` processes stuck in **uninterruptible U-state** (old binaries parked in the pre-fix `close()`-on-PTY hang) — **unkillable; a Studio reboot clears them.** Harmless/non-blocking.
- cua can't actuate `MenuBarExtra .window` popover buttons (verify host start via harness/CLI).
- Video requires Screen Recording TCC + a real Aqua session.

## Recommended future enhancement (intentionally skipped to keep the tree reviewable)
- **OSC 133 shell integration** (research §B): emit/parse command marks via the existing `ShellIntegration` shim → per-command running/done indicator in the pane + a notification when a long-running command completes. Composes cleanly now that the shim + ctty work.

---
*Generated autonomously. Verification evidence (screenshots, logs) under `/tmp/slopdesk-hw/`, `/tmp/wf*-*.png`, `.work/video-verify/`.*
