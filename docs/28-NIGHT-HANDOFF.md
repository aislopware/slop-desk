# Night Handoff — 2026-06-05 (session 2)

Autonomous bug-hunt + UX pass. Branch: **`main`**, **UNCOMMITTED** (you didn't ask to commit).
Driven by one comprehensive 8-finder "ultracode" bug-hunt workflow (each finding adversarially
verified) + independent deep reading, then fixes with regression tests, then **hardware validation
on the Mac Studio via cua-computer-use** (driven as a user — screenshots, not subjective scripts).

## TL;DR

**10 confirmed bugs fixed + 1 bonus**, every fix with a root cause, all builds + tests green
(swift build, macOS app, iOS triple, video, + full filtered test sweep). The riskiest fix
(multi-pane focus/repaint) is **hardware-validated**. **One serious new bug was discovered during
HW testing and is documented but NOT fixed** (Ctrl-C does not interrupt a foreground command —
keyboard-protocol layer; needs native-Ghostty comparison to attribute).

Regression tests added: 5 in `MuxBugFixRegressionTests` + `ConnectionRegistryTests`, 1 in
`PTYProcessTests`. All pass.

---

## Bugs fixed (all confirmed; 🟥 high, 🟧 medium)

| # | Sev | Area | Bug | Fix |
|---|-----|------|-----|-----|
| 0/1 | 🟥 | host/mux | A peer `channelClose` ran the blocking `MuxChannelSession.shutdown()` (~0.25–0.5s SIGTERM→SIGKILL `Thread.sleep`) **inline on the shared mux connection's actor receive loop**, stalling EVERY other pane on that TCP connection on each pane close (and parking a cooperative-pool thread). | New `MuxChannelSession.shutdownDetached()` offloads the kill+wait+close to a background concurrent queue; `HostServer.removeMuxSession` uses it; `stop()` parallelizes. |
| 2 | 🟥 | mux | `ConnectionRegistry` leaked a shared connection FOREVER when two panes first-connect to the SAME new host concurrently: a coalesced acquirer could resume before the build creator stored the entry, so `entries[key]?.pendingAcquires += 1` silently no-op'd then `-= 1` went negative → last-channel teardown never fired. | Create-or-fetch the entry idempotently before incrementing. |
| 3 | 🟧 | host/mux | A duplicate/retransmitted `channelOpen` for a live channel re-fired the host open hook → **double-spawned a PTY** and orphaned the first (master-fd + child + reaper leak). | `MuxNWConnection.route` only fires the hook for a NEWLY-registered channel; `HostServer.spawnMuxChannel` has an idempotency guard. |
| 4 | 🟧 | host/mux | A `channelClose` arriving BEFORE `setHostCloseHandler` was installed (the accept→install gap, or a link drop) was **dropped**, leaking the pane's shell forever — the open path buffered (`pendingHostOpens`), the close path didn't. | Symmetric `pendingHostCloses` buffer, drained in `setHostCloseHandler`. |
| 5 | 🟧 | client/mux | After a hard link drop (TCP RST / NetBird flap) a surviving sibling kept the dead `MuxNWConnection` pooled, so a reconnecting pane re-acquired the **corpse** and failed forever. | `finishLink(error:)` marks `linkFailed`/`isDead`; `openChannel` rejects a dead conn; `ConnectionRegistry.sharedConnection` evicts a dead entry and builds fresh. |
| 6 | 🟧 | client | The reconnect supervisor subscribed to `client.events` lazily INSIDE a Task created AFTER `connect()` returned — a fast `.disconnected` in that window was lost (broadcaster is live-not-replay) and **no reconnect campaign ever ran** (pane stuck "reconnecting"). | `ReconnectManager.start` captures `client.events` synchronously (eager subscribe); `ConnectionViewModel.connect` starts the supervisor BEFORE connect (cancels on failure). |
| 7 | 🟧 | video | Two clients streaming the SAME host window both minted `channelID == 1` (per-process counter from 1); the host's per-channelID reply-flow maps hijacked each other's video lane (stream theft). | Seed the client channelID allocator from a per-process random base so the id ranges never collide. |
| 8 | 🟧 | video | `VideoDecoder.decode` swallowed the VTDecompression **callback** status (`guard status == noErr … else { return }`), so an FEC mis-recovery / `kVTVideoDecoderBadDataErr` produced no pixels AND no throw → the caller's recovery (`invalidateSession` + `requestIDR`) never armed and the pane froze on the last good frame. | Capture the callback status (Sendable box) and throw `decodeFailed` so the existing recovery fires. |
| 9 | 🟧 | GUI | **macOS multi-pane**: every pane unconditionally `makeFirstResponder`'d on mount (last-mounted pane STOLE the keyboard regardless of `store.focusedPane`); and `resignFirstResponder → setFocus(false)` idled an unfocused libghostty surface's renderer → **unfocused split panes froze** (stopped repainting remote output). | Thread `isFocused` through the renderer seam (factory → `TerminalScreenView` → `PaneLeafView` → `GhosttyTerminalView`); only the workspace-focused pane takes the keyboard FR; render-focus stays ON for every visible pane (so unfocused panes keep repainting). **HW-validated** (below). |
| bonus | low | host | After a `fork()` failure, `close(slave)` ran before `errno` was read, clobbering fork's errno in the thrown `HostError.posix`. | Capture `errno` immediately after `fork()`. |

3 findings were adversarially **refuted** (shared-UDP lane leak on rapid activate/deactivate;
per-datagram Task reorder of helloAck/bye; the `attach() setFocus(true)` "multi-cursor" which is a
deliberate, documented repaint design) — not fixed, correctly.

## Hardware validation (cua, Mac Studio, real Aqua session)

Built the renderer-enabled `Aislopdesk.app` (`scripts/enable-macos-renderer.sh`), launched with
autoconnect to a local `aislopdesk-hostd`, drove it as a user:

- **#9 unfocused-pane repaint — CONFIRMED FIXED.** Streamed a `date` clock loop in pane A, split
  right (⌘D) so pane A became unfocused, and pane A's clock kept advancing across multiple
  screenshots (11:03:38 → 11:03:57 → 11:04:24 → 11:09:09) while pane B was focused. Before the fix
  it would freeze on the last frame.
- **#9 focus — CONFIRMED.** After split, typing landed in the focused pane B (not pane A);
  ⌘-arrow moved focus (focus-in report reached pane A); a click moved the focus ring (`onTapGesture
  → store.focus`). Keyboard reaches the focused pane when the window is key.
- **Also observed working:** connect-once (split inherited the host, both panes connected),
  libghostty Metal render of the remote starship prompt, OSC 133 "running…" indicator on the tab +
  pane chrome, the per-pane chrome/status dots.

### ✅ Ctrl-C does not interrupt a foreground command — **FIXED + HW-VERIFIED**
**Confirmed real on a physical keyboard** (not a synthetic-input artifact): the user pressed Ctrl-C on
a live `sleep 30` and it ran the full 30s; the terminal showed `^[[3;5u`. **Now fixed** — the user
confirmed Ctrl-C / Ctrl-Z / Ctrl-D all work.

**Root cause (verified against the ghostty source):** the libghostty key encoder picks kitty-vs-legacy
purely off `t.screens.active.kitty_keyboard.current()` (`Surface.encodeKeyOpts` → `key_encode.encode`):
non-zero kitty flags → a CSI-u escape, zero → the legacy C0 byte. The host shell (oh-my-zsh + a plugin)
ENABLES the kitty keyboard protocol, and the client's terminal mirrors that from the host output — but
the remote PTY is a SEPARATE process, so a non-kitty foreground program (`sleep`, the shell between
prompts) never receives `0x03`. There is no libghostty config to force legacy.

**Fix** (`GhosttyTerminalView.keyDown`, macOS): for a `Ctrl+<key>` whose `event.characters` is a single
C0/DEL scalar (macOS already resolves Ctrl-C→U+0003, Ctrl-[→U+001B, etc.), send that raw byte directly
via the OUT path, BYPASSING the kitty encoder; plain + non-control keys still go through libghostty
unchanged. Trade-off: a remote kitty-aware TUI (neovim) gets legacy Ctrl-keys (which every app handles)
— the right call for a remote terminal where Ctrl-C must work. (iOS hardware keys take a separate
Aislopdesk-side encoder, not libghostty, so they are unaffected.)

### (original investigation, retained) — Ctrl-C does not interrupt a foreground command
`sleep 30` in a pane ran its FULL 30s after Ctrl-C; the terminal printed **`^[[3;5u`** (a CSI-u
keyboard-protocol escape) instead of delivering byte `0x03`/SIGINT, so `sleep` never got SIGINT.

**Investigation (this session):**
- Host job control is FINE: a host-side `kill -INT` to the foreground pgroup interrupted cleanly
  (exit 130). So the host PTY / ctty / pgroup is correct — the byte `0x03` simply never arrives.
- Reproduced with **osascript `keystroke "c" using control down`** (a real-keyboard-EQUIVALENT
  event, chars=`\u{3}`, charsIgnoringModifiers=`c`), not just the cua synthetic press — so it is a
  real encoding break, not a synthetic-input artifact.
- The CLIENT (libghostty) is sending CSI-u keyboard encodings AND focus-reports (`^[[I`) that the
  host shell does not understand (it echoes them as literal text). A controlled `/bin/zsh -i` PTY
  capture with `TERM=xterm-ghostty` (the same TERM the host advertises) emits **NO** kitty-keyboard
  enable (`CSI > … u`) and **NO** focus-tracking (`?1004h`) — so the base shell config does NOT
  request these modes. The `GhosttySurface`/host PTY relay (where libghostty tracks modes by parsing
  the host's output) is therefore out of sync: the client behaves as if kitty/focus modes are ON
  while the host never requested them.

**Root-cause hypothesis:** libghostty's client surface mode state (kitty keyboard flags + focus
reporting) is not correctly synced to the HOST's terminal modes (the host runs the real PTY and is
the authority on which app-modes are active). The client must encode keys per the HOST's live mode,
defaulting to LEGACY (so Ctrl-C → `0x03`) until the host actually pushes kitty flags.

**Next steps (not done — needs libghostty mode work, unsafe to blind-fix; would risk regressing
real kitty-protocol apps like neovim):** (1) tap the live host→client PTY byte stream in a real
Aislopdesk session to confirm the host never sends `CSI > … u`; (2) check whether libghostty's
external-backend surface defaults kitty/focus modes ON, and force legacy-until-requested; (3) A/B the
same zsh under native Ghostty to rule out an env-conditional shell config. HIGH priority — a terminal
you can't ^C is broken for real dev work.

## Round-2 bug-hunt (5 more confirmed, all fixed)

A second 5-finder workflow (remote-desktop input, deep mux internals, video FEC/reassembly, output
sniffers, iOS input) found 5 more (1 refuted) — all fixed:

| Sev | Area | Bug | Fix |
|---|---|---|---|
| 🟧 | video input | Client per-event `Task`s reorder **mouseDown/mouseUp** when a hover-move is pending (the down-Task suspends on the move flush, the up-Task passes it) → host injects UP-before-DOWN → suppressed up + held-with-no-up down = **stuck button / phantom selection** (trackpad tap-to-click); same race can invert keyDown/keyUp | `VideoWindowPipeline`: route ALL outbound input (move/drag/down/up/scroll/key/text) through ONE ordered FIFO + a single consumer — enqueue is synchronous on the MainActor, so physical order is preserved |
| 🟧 | iOS input | Hardware **Ctrl/Alt+letter repeat never stops** when the modifier is released before the letter (the letter's release classifies as a plain key, missing both the repeater-key match and the routesToKeyEncoding gate) → runaway 20Hz control-code flood | `TerminalInputHost.RepeatKey` keys the repeater by a modifier-INDEPENDENT physical identity (carries the modifier-laden press as payload); `IMEProxyTextView.pressesEnded/Cancelled` ALWAYS attempts a release |
| 🟦 | sniffers | An **over-cap OSC** dropped to `.ground` mid-sequence, so its terminator `BEL` was re-parsed as a phantom `.bell` (and trailing bytes misread) | Both sniffers: an `.oscDiscard` state swallows the over-cap OSC's bytes (incl. terminator) before returning to ground — regression-tested |
| 🟦 | iOS input | Software-keyboard **Backspace during an active IME/Telex composition** swallowed the composition edit AND sent a spurious DEL to the host | `IMEProxyTextView.deleteBackward` guards on `markedTextRange` (routes to the text system during composition) |

Round-2 regression tests added: sniffer over-cap-terminator tests, a `KeyRepeater` identity-match-stops
test. (The video-input + IME fixes are iOS/GUI-only — compiled + reviewed, not headlessly testable.)

## Round-3 bug-hunt (1 more confirmed, fixed; 5 refuted)

A third 4-finder workflow (video host producer, terminal-mode tracker, workspace persistence/layout,
host backpressure) found 1 (5 refuted — the refuted set confirmed several areas SOLID: the
`TerminalModeTracker` already handles over-cap OSC correctly, malformed-tree decode is guarded, the
heartbeat-IDR re-anchor is fine):

| Sev | Area | Bug | Fix |
|---|---|---|---|
| 🟧 | host backpressure | `HostServer.stop()` **leaks the output-drain Task** (+ its retained DATA/CONTROL sub-channel actors + buffered chunk) when the drain is parked on an exhausted credit window: `stop()` doesn't route through `MuxNWConnection` (the only path that `finish()`es the sub-channels), and `outputTask.cancel()` couldn't wake the non-cancellation-aware credit park. Accumulates in the long-lived menu-bar host on every Start/Stop | `MuxSubChannel.awaitChunkCredit`'s park is now **cancellation-aware** (`withTaskCancellationHandler` + `Task.checkCancellation()`), so the existing `outputTask.cancel()` in `shutdown()` genuinely wakes + throws the parked sender. Regression-tested (`testCancelWhileBlockedWakesSenderInsteadOfLeaking`) |

## UI/UX assessment (vs Warp / Ghostty / cmux / muxy)

The client is **genuinely modern and feature-complete** for a multiplexer: vertical tab rail
(aggregate status dots, pane-count chips, drag-reorder, inline rename), tmux-style H/V splits with
per-pane chrome (kind glyph, title, status dot, split-kind menu, zoom, close, focus ring), a
Spotlight-style ⌘K fuzzy command palette (commands + tab-jump + pane-jump, terminal-conflict-safe),
per-pane reconnect status with live countdown, OSC 133 running indicator, connect-once host
inheritance, a host menu-bar app with a TCC checklist, and a responsive compact carousel. With #9,
multi-pane now behaves correctly (unfocused panes live-repaint; keyboard follows focus).

**Low-risk polish opportunities (NOT done — kept the diff tested + coherent):**
- Fix Ctrl-C (above) — by far the highest-value.
- `TerminalScreenView` carries its own StatusDot+title strip while `PaneChromeView` already shows a
  per-pane header+dot — likely redundant inside a pane; consider dropping the inner strip.
- Unfocused panes now keep libghostty render-focus (all show an active cursor); a real terminal
  dims/hollows the unfocused cursor. Cosmetic.

## Build & test status (all green)
- `swift build` (all targets), macOS app (renderer-enabled), iOS triple typecheck, video — all build.
- Full filtered test sweep green incl. new regressions. Never run bare `swift test` (HostServer E2E
  deadlocks) — use `--filter <ClassName>` (class name, not `Target.Class`).

## Files changed (uncommitted on `main`)
AislopdeskHost: `PTYProcess.swift`, `MuxChannelSession.swift`, `HostServer.swift`.
AislopdeskTransport: `Mux/MuxNWConnection.swift`, `Mux/ConnectionRegistry.swift`.
AislopdeskClient: `ReconnectManager.swift`.
AislopdeskClientUI: `Connection/ConnectionViewModel.swift`, `Terminal/TerminalRenderingView.swift`,
  `Terminal/TerminalScreenView.swift`, `Workspace/Views/PaneLeafView.swift`.
AislopdeskVideoClient: `VideoDecoder.swift`, `Mux/VideoConnectionRegistry.swift`.
App: `Apps/Shared/AppMain.swift`; renderer: `ThirdParty/.../GhosttyTerminalView.swift`.
Tests: `MuxBugFixRegressionTests.swift` (new), `ConnectionRegistryTests.swift`,
  `PTYProcessTests.swift`, `Support/InMemoryMuxLink.swift`.

`Apps/ClientApp-macOS/project.yml` was restored to the committed placeholder after HW testing
(renderer-enable is reproduced on demand by `scripts/enable-macos-renderer.sh`).

---
*Generated autonomously. HW evidence under `/tmp/aislopdesk-*.png`. Bug-hunt workflow result:
the session task output. Memory: `memory/aislopdesk-bughunt-2026-06-05.md`.*
