# 31 — Terminal-path smoothness overhaul (2026-06-12 overnight)

> **Historical session log (2026-06-12). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

**Status: DONE + reviewed + loopback-verified. ⚠️ NOT DEPLOYED — read the deploy section before restarting anything.**

After the video path reached Parsec parity, this round made the TERMINAL path (host PTY → TCP mux → libghostty) as smooth as the architecture allows. 9 commits on `main` (`1021def..58fa8ed`), full suite 1726/0, macOS + iOS apps build, `check-macos.sh --connect` PASS, cua loopback rig verified (flood + instant Ctrl-C + live RTT badge).

## What changed (one line each)

| Commit | Change |
|---|---|
| `1021def` | Client IN batch-drain: `SlopDeskClient` inbox + `bufferingNewest(1)` wake + `takeOutputBatch`; `TerminalViewModel.ingestBatch` 256 KiB budget passes; `GhosttySurface.feedBatch` = N writes + ONE refresh/present per batch |
| `6e3f4fe` | Host drain-merge (≤32 KiB, `.exit` barrier) + fused `HostOutputSniffer` (1 pass, memchr fast path; 60→264 MiB/s worst-case) + control-sender split + queue 256→64 KiB + read chunk 128→32 KiB + `MuxByteLink.sendPipelined` |
| `d81b275` | **Credit-at-consumption**: grants fire from the real consumer (`MuxSubChannel.noteConsumed` → `recordConsumed`), window 256→64 KiB, input split 16 KiB, host PTY writes on a dedicated queue |
| `3be3b01` | OUT drain off-main + `packInputs` (merge tiny / split 16 KiB, resize barrier) + SINGLE input funnel (`InputBarModel.sendSink`; iOS dual-drain + macOS submit-Task deleted — docs/29 fix) |
| `8f0c0f2` | Render: layout same-size guard (macOS+iOS), display-link idle pause, iOS gated tick (simulator keeps free-run) |
| `af868f9` | Ping/pong RTT (wire types 14/24, control channel, 3 s, EWMA α=0.25) → `ConnectionViewModel.latencyMS` |
| `7183aca` | Review-round fixes: **13-byte dead-zone stall** (see below), reconnect inbox clear, cancelled-observe guard, controlOut bound, exit latch 2→10 s |
| `7145114` | Live RTT badge in the pane chrome (amber >100 ms) |
| `58fa8ed` | Cancelled ingest stops mid-batch between budget passes |

## Why it's smoother (the mechanisms)

- **Flood no longer owns the main thread**: one MainActor pass per backlog (budget 256 KiB + yield) instead of one job + one VT parse + one renderer wakeup per wire chunk. VT parse runs ON the calling thread (fork patch `:2284`) — that's why batching matters.
- **Echo head-of-line under flood**: in-host committed backlog ~640 KiB → ~96 KiB; in-flight window 256→64 KiB. At the live ~12 Mbps WAN: ~437 ms → ~87 ms worst.
- **Ctrl-C is instant**: credit-at-consumption bounds client-side un-rendered bytes to ~2 windows (~128 KiB). Verified on the rig: the prompt is back in the same screenshot as the press.
- **Typing under flood**: the OUT drain runs off-main (keystroke sends no longer queue behind ingest/render main-actor work).
- **Idle panes are free**: display link pauses when presentTicks drain; iOS device tick is gated (was 60 Hz × pane forever).

## ⚠️ DEPLOY: both ends TOGETHER, or stall

`MuxFlowControl.initialWindowBytes` (256→64 KiB) is a both-ends constant with NO negotiation, and `ping` (type 14) is channel-fatal to an old decoder. **Old client + new host = permanent channel stall on the first flood** (old grant threshold 128 KiB > new window 64 KiB). The Studio production hostd (`.build/release/slopdesk-hostd --port 7420`) is still the OLD binary on purpose; the MacBook was offline (ssh timeout) so nothing was deployed. Redeploy host + MacBook client in one go (recipe in the run-server-client memory / docs/21).

## The review round's lesson (worth keeping)

27-agent adversarial review of the night's diff caught a HIGH the 1726-test suite couldn't: frame caps bounded **payload** while the sender debits **wire bytes** (payload + 13-byte `.output` header) → max frame 32 781 > window/2 32 768 → a credit park whose partial-frame prefix landed in that 13-byte dead zone could never re-grant (receiver can only credit COMPLETE decoded frames). Rule of thumb now encoded in `MuxFlowControl.maxOutputFramePayloadBytes = min(mergeCap, window/2 − 16)` + head-chunk splitting: **with credit-at-consumption, always reason in wire bytes, and only complete-frame bytes are creditable.**

## Knobs (env)

`SLOPDESK_MUX_WINDOW` (⚠️ set identically in BOTH processes), `SLOPDESK_MUX_HOST_QUEUE` (host-local), `SLOPDESK_MUX_MERGE_CAP` (cross-clamped — safe at any in-range value).

## Loopback feel-test (cua-driven, 2026-06-12 morning — Mac Studio rig)

All interactive scenarios pass on the loopback rig (debug hostd :47421 + GUI app autoconnect, `SLOPDESK_ECHO_PROBE=1`):

- **Type-under-flood**: keys land instantly during a 41 s `yes` flood; RTT badge stays <1 ms; Ctrl-C → `^C` + fresh prompt in the very next frame.
- **TUI (Neovim)**: dashboard (25 plugins), insert-mode typing, statusline, alt-screen enter/exit all render clean; scrollback restored exactly on exit.
- **Pane maximize/restore**: `stty size` → `35 112` after maximize (host PTY tracked the reflow); restore returns the original grid, no garble, no crash (old maximize-rebuild bug stays fixed). Note: window drag-resize does NOT resize panes — infinite canvas, panes are 1:1; pane-level resize is maximize/restore (or future pane handles).
- **Cross-pane isolation**: pane 2 inherits the connection (connect-once) and floods while pane 1 runs `echo hi` instantly at <1 ms RTT — one mux, no head-of-line across sub-channels.
- **Echo probe over the whole session**: n=61, median **2.5 ms**, p95 9.8 ms, max 68 ms (single outlier during Neovim plugin load). hostd idle CPU 0.0 % after teardown (display-link/idle pause working), zero errors in hostd log.

## Follow-up round (2026-06-12 morning — #6, #5, #3 all DONE)

Commits `75f4d95` + `88e51b4` + `3dbe2e3` + review-round `117ea19`, suite 1761/0, macOS+iOS build, rig-verified.

- **#6 `TerminalModeTracker` memchr skim fast path** (`75f4d95`): ground 207→40,914 MiB/s (×197), markers-every-4KiB ×16, all-ESC worst case still ×1.8. Pinned by a chunking-invariance oracle + a differential oracle vs the frozen pre-fast-path copy (`Tests/SlopDeskClaudeCodeTests/Support/LegacyTerminalModeTracker.swift`). Done first because #3 wires the tracker into `ingestPass` (the flood hot path).
- **#5 Off-main feed** (`88e51b4`): `GhosttySurface.feed/feedBatch` are `nonisolated` enqueues onto a per-surface `SerialFeedGate` serial queue (the fork's contract is per-surface *serialization*, not main-thread-ness; the VT parse runs on the calling thread under the renderer mutex — that parse left the main actor). write_output→refresh stay synchronous inside one queue block; present arming hops main async. **Backpressure**: `FeedBackpressuring` (separate `Sendable` protocol) — `ingestBatch` awaits it before every pass so credit-at-consumption stays coupled to parse progress (high water 512 KiB). ⚠️ Echo-probe semantics changed: it now measures key→ingest+enqueue (the parse left the measured segment) — do not compare to the 12.4 ms pre-change number.
- **#3 Glitch caret v1** (`3dbe2e3`): docs/17 §2.4 conservative form — `SLOPDESK_GLITCH_CARET=1` (RTT-hysteresis-gated, arm >30 ms / disarm <20 ms) or `=force` (rig). Single printable byte with no output within 175 ms → dim pulsing corner nudge; ANY ingest hides; 1.5 s expiry; backspace retires one; CR/ESC/multi-byte (paste/IME) clears all. Alt-screen gated via the mode tracker fed in `ingestPass`. Never paints predicted text; not cell-anchored (no cursor readback in the C API — v1b = fork patch `ghostty_surface_cursor_cell`). **Default OFF** — flip on after a real-WAN feel pass.
- **Review round** (`117ea19`, 41-agent adversarial, 8 confirmed): the HIGH was a `closeBarrier` **deadlock** — a feed block can park inside `write_output` on libghostty's 64-slot app mailbox whose only consumer is `ghostty_app_tick` on MAIN, so a `queue.sync` from main hangs the app; `close()` now defers `ghostty_surface_free` into the gate's non-blocking drain completion (strong-self capture keeps the C callbacks' unretained `userdata` alive). Plus: cancellation + `sessionEpoch` guards after the backpressure park (dead-session bytes can't consume the fresh-session wipe), `TerminalModeTracker.reset()` at session boundaries (a drop inside vim used to latch `.altScreen` and permanently disarm the caret), and the caret fade animation actually animating.

Rig evidence (`/tmp/slopdesk-rig2/shot-*.png`): caret shows under `stty -echo; read x` and clears on output; flood RSS flat at 150 MiB (backpressure); Ctrl-C instant; **close-pane-mid-flood** twice (sync-barrier build AND async-close build) — no crash, survivor pane clean; echo probe n=37 median 3.9 ms p95 5.5 ms max 10.4 ms.

## Follow-ups (ranked)

1. **Deploy both ends + WAN feel-test** — PARKED: user says the MacBook Pro will stay offline; loopback portion above is done. When the MacBook returns, deploy host + client together (see deploy section), then feel-test WAN typing and consider defaulting `SLOPDESK_GLITCH_CARET=1` on.
2. **iOS real-device check** of the gated tick (type/echo, pan-scrollback, cursor blink) — simulator keeps the free-run deliberately; blink rides the renderer's own present path in theory, unverified on device.
3. **Glitch caret v1b** — cell anchoring via a fork patch exporting `ghostty_surface_cursor_cell` (patch pipeline precedent: patches/0001+0002); costs an xcframework rebuild + rebase burden, so only worth it if the corner nudge feels too detached on real WAN.
4. ~~Echo-RTT AUTOTYPE instrumentation~~ — **DONE** (`411491d`). ~~#5 off-main feed~~, ~~#6 tracker fast path~~, ~~#3 glitch caret~~ — **DONE** (above).
