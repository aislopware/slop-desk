# 72 — The terminal-and-remote-desktop audit of 2026-09-02, and what it changed

The second pass of the day, after `docs/70`, with a narrower question and a deeper method: does the
terminal render every frame of a complex TUI the way ghostty does, and does the remote desktop beat
Parsec on input and output? Everything else in the tree was read too; the code-server panel and the
iOS simulator pane were skipped because both are being replaced (`docs/DECISIONS.md`).

Read `docs/70` for what the first pass fixed and rejected — nothing here re-derives it — and
`docs/71` for the smoothness harness whose numbers this pass extends. `docs/68` §6.6 is the
terminal half of this pass in the terminal's own terms.

## 1. What was checked, and how

Nine audit agents, one per surface, each reading every line in scope and executing what it
suspected before reporting; then the fixes, applied inline against each report and gated per crate.
Every "confirmed" finding below was reproduced against the real engine, the real crate, or the real
daemon — not reasoned from a synthetic input.

| Surface | Oracle / method |
| --- | --- |
| `slopdesk-vterm` (engine, key and pointer encoders, frame extraction) | ghostty `22d13172` source and the §6.4 Formatter oracle; a scratch probe against the real `libghostty-vt` for every key and mouse claim |
| `slopdesk-termrender`, `slopdesk-apple-metal`, `slopdesk-apple-text` | ghostty's renderer and font metrics; a Metal probe and a paint bench |
| The Swift terminal view and the key path | ghostty's `SurfaceView_AppKit.swift`; the door's exact `KeyPress` construction replayed through the engine |
| PTY byte path, superd → hostd → mux → client | a scratch copy of `slopdesk-clientdriver` with a fake host that ships data before the ack, 20 runs per case |
| Video host output (SCK → VT → packetize → pace → send) | line-by-line trace; C and Objective-C benches for the IOSurface rebuild and the VideoToolbox VUI behaviour |
| Video client (receive → reassemble → decode → present, audio) | a present-queue cadence simulator against the shipped crate; a VideoToolbox decode probe |
| Video input (NSEvent/UIKit → wire → CGEvent inject) and the cursor channel | trace of every event kind; the injector's own fakes |
| Wire, mux, credit, FEC, gfsimd, golden | 415 wire tests, `just miri`, and a 30 s × 5 LCG fuzzer over every decoder, the reassembler and FEC recovery |
| Everything else (hostd, hook, settings, workspace, daemons, posix, client shell) | read against `docs/50`–`54`; every scope crate's tests |

## 2. Fixed

Each entry names the crate or file, what was wrong, and the test that now holds it. Where a
number decided the fix, the number is in §5.

### 2.1 Terminal — engine and renderer

- **Bold brightened the colour.** ghostty's `bold-color` is unset by default, so `SGR 1;31` is dark
  red in bold; the frame now resolves colours from the raw style and never lifts bold into the
  bright palette. `slopdesk-vterm/src/session.rs` module doc "Bold does NOT brighten".
- **SGR 8 (conceal), inverse and faint read resolved colours.** Inverse swaps and faint blends
  against the style's own bits, which a pre-resolved colour has lost. Same module.
- **DEC 2026 synchronized output was ignored.** `VtSession::render` now holds the last frame while
  the mode is set and catches up in one pass at the close; a hold older than one second is broken
  by clearing the mode, which is ghostty's `sync_reset_ms`. The FFI draw answers HELD so the view
  re-polls. `docs/68` §6.6.
- **Underlines were drawn over the glyph.** Underlines and overlines now go in a pass under the
  text, so a descender crosses the line instead of being cut by it; strikethrough stays above.
  `slopdesk-apple-metal/src/renderer.rs`, test
  `a_strikethrough_draws_over_the_text_and_an_overline_under_it`.
- **A block cursor on a wide glyph covered one cell.** Block and hollow carets span both cells
  (ghostty's `cursor_wide`); bar and underline stay one. `termrender/src/layout.rs`, test
  `a_block_cursor_on_a_wide_glyph_covers_both_cells`.
- **The glyph under a block cursor kept the cell's background.** It now takes the default
  background unless the theme names `cursor_text`, which is ghostty's unset `cursor-text`.
- **Metal drew the buffer's capacity, not the frame's count.** The instance buffer doubles and never
  shrinks, so a small frame after a large one re-drew the large frame's tail: a deselected
  paragraph's fill, a hidden cursor's block, three presents stale. `InstanceBuffer::fill` now answers
  `Bound { buffer, count }` and every draw call names the count. Test
  `a_fill_answers_the_instances_written_and_not_the_buffers_capacity`.
- **Font metrics rounded differently from ghostty.** Cell width, natural height, cell height,
  baseline and underline thickness now follow `src/font/Metrics.zig` exactly, including the odd
  line-height gain rule. `slopdesk-apple-text/src/font.rs`. The cursor thickness keeps its
  `max(thickness + 1, 2)` floor as a deliberate divergence — a one-pixel caret is a UI defect at
  1×.
- **The atlas refused every glyph past 4096².** At the ceiling the cache now resets and repacks
  instead of caching `None` forever. `termrender/src/glyph.rs`, test
  `an_atlas_at_its_ceiling_is_repacked_rather_than_refusing_every_glyph_after`.
- **Every display tick repainted and resubmitted.** `slopdesk_term_surface_draw` answers
  nowhere / drawn / skipped / held; a clean engine frame with no repaint owed and the same graphics
  generation skips the paint and the GPU submit. Every door that changes what is drawn without
  touching the engine sets the repaint flag. `docs/68` §6.6.
- **The key press shape was not ghostty's.** The Mac view sent raw `event.characters`; it now sends
  the layout translation without control, `consumed_mods` without control and command, and the
  unshifted codepoint, and the PUA/control-led filter lives in the Rust key door. The dead
  `KeyEventTextPolicy` and its test are deleted. Modifier presses are forwarded from
  `flagsChanged`.
- **Blink had no clock.** A 600 ms phase in the display-link tick, gated on `wants_blink` (a blinking
  cursor not over a password field, or an SGR 5 cell), cached per drawn frame and reset on a
  keystroke. SGR 5 text keeps blinking here where ghostty draws it steady — a recorded divergence.
- **Wheel under a mouse-tracking program scrolled the viewport.** `owns_wheel` and `wheel` doors:
  button 4/5 presses per row, or cursor keys under alternate-scroll, with the sub-row remainder
  carried across events. The view's old button-4 mouse path is gone.
- **The pointer encoder resynced per event.** A mouse-mode change is learnt at the feed, where it
  can happen, not per event where it forgot the last reported cell.
- **A backing-scale change kept the old metrics.** `viewDidChangeBackingProperties` re-measures.

### 2.2 The PTY byte path

- **A restore the size of one window wedged the pane.** The host's first frames ride the data link
  and the open's verdict rides the control link, so a transcript could be folded against the
  previous connection's marks and have its credit zeroed by the ack. `slopdesk-clientdriver` now
  stages any chunk that arrives before its epoch's adoption and feeds the list through the session
  once the marks are the ack's; the host acks before the start so the verdict never trails the
  drain. Reproduced 15 wedged / 20 before; `tests/preack.rs` after.
- **superd's ring was walked a byte at a time under its lock on every subscribe.** Two memcpys.
  `ring.rs`, test `a_wrapped_ring_resumes_bit_exactly_from_either_half`.
- **The subscribe seam delivered one chunk twice.** `hostpane/src/stream.rs` cuts the overlap off
  the front by absolute offset and only ever moves its mark forward.
- **`tcgetattr` ran per input message.** One sample per scheduler quantum; a paste or a key repeat
  samples once per gap. `hostsession/src/subscriber.rs`.

### 2.3 Video host

- **Parity datagrams were 1204 bytes.** Parity shards are length-prefixed, so
  `MAX_PAYLOAD_SIZE` is now the datagram less the header less the four-byte prefix (1177), the
  packetizer's MTU test bounds every datagram by `MAX_DATAGRAM_SIZE`, and the reassembler's payload
  cap admits a full parity fragment and refuses one byte more. `docs/20` §9.3.
- **Every decoupled live frame allocated a fresh IOSurface.** The drain draws from a
  `PixelBufferPool` on its own thread; the pooled rebuild is a third of the fresh one at 1080p
  (§5). `slopdesk-apple-vt/src/pixels.rs`, `videohostd/src/capture.rs`.
- **A frozen client waited a heartbeat.** A forced recovery request is served two capture
  intervals after the last real frame, and the capture timer wakes for it instead of polling.
  `recovery_routing.rs`, test
  `a_frozen_client_is_served_two_capture_intervals_after_the_last_live_frame`.
- **Colour metadata depended on the input buffer.** VideoToolbox lifts no colour description from
  attachments, so the three BT.709 keys are set on every encoder session; +5 bytes per keyframe.
- **A retired encoder was dropped mid-frame across a resize.** `Retired::complete_frames` drains it
  between the slot swap and the stream reconfigure.
- **The send path took the mux state lock and allocated per datagram.** `send_many` resolves the
  peer once per same-channel run, the sendlane groups consecutive same-channel datagrams, the
  interleaver permutes finished datagrams instead of re-encoding fragments, a refused send is
  retried once after a yield and counted, and the media socket's buffers are widened to 4 MiB.
- **The cursor channel sent 120 datagrams a second idle.** Position dedup with a 1 Hz keep-alive,
  and the shape refresh is seed-driven (a change lands on its tick) instead of 30 TIFF encodes a
  second. `docs/20` §9.6.

### 2.4 Video client

- **The present queue ratcheted to the hard cap under motion.** Homeostasis trims to the live
  depth on every present; the re-prime floor is two slots; refreshes are counted in content slots
  so a 120 Hz link does not read the ticks between 60 fps arrivals as starvation.
  `slopdesk-video/src/present_queue.rs` module doc; `PacerDepthPolicy.swift`.
- **A second arrival inside one vsync interval under a locked present pushed the first out.**
  `FramePacer.presentNow` marks `needsRedisplay` and returns; macOS only when `SLOPDESK_VSYNC=1`,
  iOS always. iOS also sets `CADisableMinimumFrameDurationOnPhone`.
- **The reassembled frame was copied twice on the way to the decoder.** `parkedFrame` writes the
  AVCC straight into the `Data` the decoder takes.
- **A window-feed record was folded through a clone per chunk.** `window_feed.rs` folds in place.

### 2.5 Video input and the wire

- **Scroll posted at the last hovered pointer.** The injector puts the pointer where the gesture
  happened before the wheel, once per place. Fixes multi-pane and the phone.
- **Nothing was released on final teardown.** Every held button, modifier and open scroll gesture
  is released outside the seam lock; a re-mint carries, a teardown releases.
- **The middle button was never forwarded.** `otherMouse*` overrides on the Mac view.
- **Key repeat and scroll modifiers were not on the wire.** Type 5's down byte is a state byte
  (bit 0 down, bit 1 autorepeat) and the host stamps `kCGKeyboardEventAutorepeat`; type 4 gains a
  trailing modifiers byte, decoded as unmodified when absent, and `post_scroll` sets the flags on
  the event so a ⌘-wheel from a client that sent no ⌘ key edge still zooms. Golden re-minted
  through the Swift suite. `docs/20` §9.7.
- **The inbound pump took a state lock per input datagram.** Once per batch.

### 2.6 Everything else

- **The hook installer could replace a user's `settings.json` with a hooks-only file.** A file that
  exists but does not decode is an error, not an empty root, and the settings are read before the
  relay is staged. `slopdesk-hook/src/install.rs`, test
  `a_missing_settings_file_reads_as_nothing_and_a_corrupt_one_as_an_error`.
- **Invariants.** `pane-client-session` follows the adopt call's new shape; `wire-enums-agree`
  no longer reads a `match` on `MouseButton` as a wire alphabet; the `WIDE` LOC caps for
  `apple-vt`, `apple-metal` and `apple-text` are raised with their reasons (`docs/57` §3.4).

## 3. Rejected or reclassified, with the evidence

- **Vsync-locked present as the default.** Measured at `--fps 30` it costs +6 ms at p50 for a
  metronome cadence, and was flipped on with the 60 fps default; re-measured the same day at 60 it
  costs two frames (p50 50.5 / p90 52.8 ms against 21.2 / 28.2 unlocked, non-overlapping
  distributions, a three-frame spread). Content rate-matched to refresh fills the pacer and both
  drawables, so every frame waits out a queue. Parsec's `client_vsync` defaults on and pays the
  same. Default off; `SLOPDESK_VSYNC=1` is the A/B; the locked cadence is a target for the present
  path, not a default (`docs/decisions/vol-14.md`).
- **"Client outbound input shares an executor with synchronous decode".** Not real at defaults:
  decode runs on its own serial queue (`SLOPDESK_DECODE_OFFQUEUE` on), so a send waits at most
  behind one `receiveBatch` drain, under a millisecond. Measured decode wall at 1280×800 HEVC:
  delta p50 0.7 ms, warm IDR 2.7–5 ms, the first IDR after a session create 105 ms.
- **The wire layer.** No correctness defect: 35 M framing iterations, 60 M mux iterations, 72 M
  video-datagram iterations, 1 M hostile reassembler iterations and 7.4 M FEC recoveries, zero
  panics, every round-trip byte-identical. What it found was allocation counts (§2.3) and the
  parity MTU overrun (§2.3), which the fuzzer could not see because it never sent a datagram.
- **The delta pace floor (12 Mbps × 2.5).** A fixed serialisation tax of `1 / (2.5 × fps)` per
  ABR-sized frame — 7.7 ms on the average 60 fps frame, 49 ms on a keyframe — but the only measured
  alternative is LAN-only and removes burst protection on a constrained hop that was not measured
  this session. The floor waits for a `just gui-smooth` run on the Wi-Fi hop.
- **Painter dirty-row reuse.** Rebuilding only the damaged rows' quads would save a measured
  0.5 ms per frame on a full-screen TUI — under the veto, and the draw skip (§2.1) already removes
  the whole paint on an idle tick, which is the common case.
- **SGR 5 text drawn steady.** ghostty does; here it blinks on the same 600 ms clock as the
  cursor. Kept: a program that asks for blink gets blink, and the gate is a cached per-frame flag.
- **A mux-prefix-reserved send arena.** Would remove the last per-datagram allocation on the host
  send path; unmeasured, and `send_many` already removed the lock and the peer lookup.
- **An audio servo on the client.** No measured drift on the loopback or Wi-Fi hop this session.
- **The phone's soft keyboard as a key stream, and a synthesised momentum tail.** Both change what
  the phone sends without a phone measurement; deferred with the phone parity ledger.

## 4. Verified clean

Recorded so the next pass does not re-derive it. One line each; the audit reports carry the trace.

- Terminal engine: OSC 8/52/133 handling, DECRQM answers, the alt-screen resize path, grapheme
  width against the engine's own tables, the pointer encoder's SGR/URXVT/X10 formats.
- Terminal view: `modeTracker` is Rust; `mouseExited` without a button is dropped as ghostty does;
  IME order (`interpretKeyEvents` before `send`); right/middle balancing; Shift-click override;
  `drawableSize`/`contentsScale` set together.
- PTY path: superd owns every master `read`; the ring's offsets are absolute and monotone; the
  64 KiB window's half-window grant and the credit-progress invariant hold for every frame the host
  can emit; `TCP_NODELAY` and keepalive at both ends; sanitize runs only on the cold replay.
- Video host: VT property set is the optimal low-latency set; PTS monotonic across live and
  synthetic; lock order consistent everywhere traced; `Capturer::stop` idempotent; recovery IDR
  bucket cannot starve.
- Video client: NV12 → Metal zero-copy; BT.709 from the Rust crate only; present-on-arrival race
  closed by identity skip plus `needsRedisplay`; keepalive, stall and hello deadlines; iOS
  background pause inside a background task.
- Wire: every credit site credits `wire_byte_count()`; ids never reused; refusal outside the lock;
  every decoder checks counts before allocating; gfsimd's NEON masks every lane index and `just miri`
  interprets the NEON path itself.
- Everything else: `slopdesk-posix` fork window; the hook socket's caps; metadata verbs on the
  bounded executor; the settings resolver never fails a launch.

## 5. Measurements

| What | Number | How |
| --- | --- | --- |
| Glass-to-glass, 60 fps default, vsync off, loopback, 30 pairs | p50 21.2 / p90 28.2 ms | `just gui-smooth --latency` |
| Same, `SLOPDESK_VSYNC=1` | p50 50.5 / p90 52.8 ms | `SLOPDESK_VSYNC=1 just gui-smooth --latency` |
| Cadence, 60 fps default | 60.3 / 60.3 new/s, ratio 0.99, 0 stalls, 0 steps, 0 gaps | `just gui-smooth` |
| Client HEVC decode wall, 1280×800 | delta p50 0.70 / p90 0.87–1.0 / max 1.3 ms; IDR 2.7–5.0 ms warm, 105 ms cold | a VideoToolbox decode probe |
| IOSurface rebuild per frame, fresh vs pool vs memcpy, 1080p | 0.33 / 0.10 / 0.093 ms | a C bench over `CVPixelBufferCreate` |
| Same at 4K | 1.16 / 0.31 / 0.28 ms | same |
| Painter quad rebuild, full-screen TUI, per frame | 0.5 ms | the termrender paint bench |
| Pre-ack credit wedge, 64 KiB before the ack, 20 runs | 15 wedged, 4 partial, 1 clean before; 0 after | `slopdesk-clientdriver/tests/preack.rs` |
| Wire fuzz | 35 M framing, 60 M mux, 72 M datagram, 1 M reassembler, 7.4 M FEC — 0 panics | an LCG fuzzer over every decoder |

## 6. How to re-run this

The durable parts are the tests each fix carries, the harness in `docs/71`, and the ghostty oracle
under `ThirdParty/tools/.prefix/ghostty`. To repeat the pass: read one surface at a time against its
oracle, execute every suspicion before writing it down, and fix inline crate by crate with the
crate's own gate — the fan-out that produced the audit reports cost an order of magnitude more
tokens than the fixes did, and the reports were the only part of it that had to be parallel.
