# 61 — Deleting `Sources/SlopDeskVideoHost`

**This is a record. `Sources/SlopDeskVideoHost` is deleted and `rust/slopdesk-videohostd` is the
daemon.** The file is kept because every section below holds a REASON — why a rule was re-aimed
rather than dropped, why an instrument was dissolved rather than ported, which divergences from the
Swift are deliberate — and those are what a reader needs the day one of them looks like a mistake.
Read §3 for what is knowingly not the same as the Swift; the rest is history with its arguments
attached.

`CLAUDE.md` says a port deletes its original in the same change. This tree was the ONE place that
rule was deferred, and the deferral is what this file bought.

The reason was arithmetic, not preference. `SlopDeskVideoHostSession.swift` was 2051 code lines and
the only thing that OWNED the other 46 files — the capturer, the encoder, the packetizer, the
injector and the window feed were reached through it and through nothing else. Deleting the tree
before that file was ported would have deleted a working daemon and left nothing that serves;
deleting it one file at a time would have meant a fallback, a shim or a cross-language mirror at
every step, each of which `CLAUDE.md` names by name. So the tree went in ONE commit, with the
session, and every row of §1 was green in that same commit.

**The Rust side landed meanwhile, and reached Swift at no point.** No FFI door was ever added for
any of `rust/slopdesk-videohostd`, which is why the deletion had no bridge to unpick — §5 is the
door surface that died with the Swift, not a surface that had to be disconnected first.

## §1 The cascade — everything that moved in the deletion commit

**Every row below is CLOSED.** The table is kept as a record rather than a plan, because each row's
fourth column holds the reason the thing was done the way it was, and those reasons are what a
reader needs the day one of them looks re-openable. `Where` is where the thing USED to be; the ✅
column says what stands there now. Nothing here is outstanding — the open work this document still
tracks is in §3's named divergences, not in this table.

| # | What | Where it was | What it took |
| --- | --- | --- | --- |
| 1 | `SlopDeskVideoHostSession.swift` | `Sources/SlopDeskVideoHost/` | ✅ the port itself: 2051 lines, the keystone. The whole directory is gone |
| 2 | the `SlopDeskVideoHost` library product | `Package.swift:121` | ✅ deleted |
| 3 | the `SlopDeskVideoHost` target | `Package.swift:699` | ✅ deleted |
| 4 | the `slopdesk-videohostd` executable target | `Package.swift:811-817` | ✅ deleted — the Rust binary is the daemon |
| 5 | `slopdesk-perfbench` | `Package.swift:832-836` | ✅ DISSOLVED, not retargeted. The headless encode/decode timing benchmark is `rust/slopdesk-loopback-validate` (`just loopback-validate`, `docs/46`). It was a Swift target only because it drove `VideoEncoder`, `VideoDecoder` and the packetizer directly, and all three are Rust now — a Swift harness over the door would have measured a reimplementation rather than the object the host drives, which is §2's own argument. Its encode-wall findings survive in `docs/research/perf-2026-07-04-encode-wall.md` |
| 6 | `slopdesk-framewatch` | `Package.swift:816-820` | ✅ RETARGETED. It had NO `SlopDeskVideoHost` edge — an SCK capture that logs arrival timestamps — and `rust/slopdesk-apple-sck` covered it, so it is `rust/slopdesk-instruments`' `slopdesk-framewatch` bin: same flags, same stdout format, `CaptureStream` instead of a hand-rolled `SCStreamConfiguration`, and the luma plane read as a `&[u8]` through `slopdesk-apple-vt` so the instruments workspace stays `forbid(unsafe_code)`. The Swift target is deleted and `deleted_host_swift::swift_instruments_stay_deleted` keeps it deleted; `rust_boundaries::capture_is_rusts` lost its last exemption with it |
| 7 | `SlopDeskVideoHostTests` | `Package.swift:1071` | ✅ deleted with its target. What it tested — the host-session state machine, the resize ladder, the recovery verbs — is `rust/slopdesk-videohostd`'s and `rust/slopdesk-video`'s now, under `just videohostd-test` |
| 8 | the `apple_floors` rules that name the tree | `rust/slopdesk-invariants/src/rules/apple_floors.rs:35,188,358,405,575,583` | ✅ RE-AIMED, never dropped, and their break-tests with them. Each named a path under `Sources/SlopDeskVideoHost/` or `Sources/slopdesk-videohostd/`; the surviving pair points at `rust/slopdesk-apple-cgevent/src/inject.rs` and `rust/slopdesk-videohostd/src/injector.rs` — the Rust that replaced the subject, which is the treatment rows 12 and 14 both cite |
| 9 | the devtools GUI's video page | `rust/slopdesk-devtools/src/gui/mod.rs`, `gui/video.rs` | ✅ nothing to move: it names the DAEMON — `slopdesk-videohostd --list`, its binary and its socket — and never named the Swift target. The check was the row's whole content and it came back clean |
| 10 | `EnvBridge.loadDefaultSidecarIntoEnvConfig` | Swift client side | ✅ gone with the launch path; `crate::env::Overlay` is the daemon's `setenv` fold. `EnvBridge.swift` keeps a note at the old site saying so, which is what stops the one-liner being re-added by someone reading the file rather than this table |
| 11 | `docs/00` and `docs/01` | prose | ✅ `docs/00` §"The system calls are Rust's too" now names `slopdesk-videohostd` as the Rust GUI video host and narrows the Swift remainder to Metal/CAMetalLayer, Network.framework on the CLIENT, and the two view layers. `docs/01` never carried the claim |
| 12 | the four `slopdesk-videohostd` names in `STRANDED_RUST_MODULES` | `rust/slopdesk-invariants/src/rules/repo_invariants.rs` | ✅ PAID, and then paid AGAIN for a reason the register could not show. `encode`, `feed`, `mux_registry` and `windowgeometry` came off as the port reached them and the list is `[&str; 0]`. But an empty register only means no name is EXCUSED — and `windowgeometry` and `cursor` were passing on text rather than on a caller: a sibling's `///` link spelling the qualified path, a homonym module in `slopdesk-video` reached with `crate::`, and that crate's root re-exporting its own `cursor`. Both modules were written, unit-tested and CONSTRUCTED NOWHERE. Closing the three holes turned them red, and `session_geometry.rs` is the composition that answers — every door they needed was already open. Each hole now carries its own break-test |
| 13 | the host's whole FFI door surface | `rust/slopdesk-ffi/` | ✅ 248 doors across 26 modules had the deleted Swift as their ONLY caller and died with it — plus the three settings faces that were the last thing keeping four of those modules alive (`HostGateTable`, `CaptureGateTable`, `InjectorGateTable`). Six more modules SHRANK to the doors a client still opens. See §5 |
| 14 | the `drag-cadence-ratchet` rule | `rust/slopdesk-invariants/src/rules/window_placement.rs` | ✅ RE-AIMED the way row 8 treats `apple_floors`, and its break-tests came along. It used to be a `SameSet` across the port — `dragPollHz` and `unionPollDivider` in the Swift watcher had to equal `DRAG_POLL_HZ` and `UNION_POLL_DIVIDER` — and a `SameSet` whose Swift side does not exist is the vacuous pass this crate refuses. What it protected outlived its Swift half: both are still NAMED constants in `windowgeometry.rs`, and the daemon may not type either as a literal. A hand-typed `from_millis(33)` is 30.3 Hz — near enough that nothing looks wrong, far enough that the region sample drifts off the drag it belongs to |

## §2 The one architectural debt the port took on — PAID, in the deletion commit

`rust/slopdesk-videohostd` used to depend on `slopdesk-ffi`, which is the Swift shim crate, and that
edge would be wrong in any other daemon. It was there because `slopdesk-ffi::encoder` held the
ENCODER DRIVER, and the driver held one `unsafe` obligation that is legal in exactly three crates:
HEVC parameter sets have no copy-out variant in the SDK, so `slopdesk-apple-vt` answered them as
`(ptr, len)` values and the single `slice::from_raw_parts` that laid them in front of a slice was
made in `slopdesk-ffi`, whose whole remit `docs/57` §2 states is that question.

Three ways out were checked and two failed on the repo's own terms:

- **A crate of its own for the driver.** A fourth hand-written-`unsafe` crate. `CLAUDE.md` admits one
  only for a MEASURED perf conflict; this is code organisation, so it does not clear the bar.
- **Put the driver in `slopdesk-videohostd`.** That crate is `forbid(unsafe_code)` like every crate
  outside the two families. The slice could not be written there at all.
- **Amend `docs/57`'s buffer paragraph to give `slopdesk-apple-vt` the exemption
  `slopdesk-apple-audio` has.** This is the one that works — but it could not be taken early. The
  audio exemption was granted only because that crate's "move the obligation to `slopdesk-ffi`"
  escape hatch was a dependency CYCLE. For `slopdesk-apple-vt` the hatch existed and was already
  taken, so the doc's own three-route test rejected the amendment while `slopdesk-ffi` was still the
  natural home.

It stopped being the natural home the moment the C doors died, which is this deletion. The
amendment landed here, and what landed is NARROWER than the three edits above anticipated:

1. `slopdesk-apple-vt` gained `copy_parameter_sets_into(&mut Vec<u8>)`, written the way
   `copy_payload_into` already was. `FrameworkBytes`, `parameter_sets()` and `contiguous_payload()`
   were then DELETED outright, so the crate answers only copies and no framework pointer leaves it.
2. A second, unplanned move came with it. `slopdesk-ffi::pixel_plane` existed for no reason but
   "this crate may write `unsafe` and apple-vt may not": it turned a locked buffer's
   `(base, stride)` into a slice for the capture path and the loopback harness. With the daemon no
   longer linking the shim, that module had no home, so the mapping went to the crate that locks the
   buffer — `Locked::plane_view` and `Locked::plane_mut` — and `pixel_plane.rs` was deleted. The raw
   `Plane` type is private now.
3. The driver moved to `rust/slopdesk-videohostd/src/encode.rs`, which is `forbid(unsafe_code)`. It
   needed no exemption of its own, precisely because of 1 and 2.
4. `CSink`, `CallerContext`, `SlopDeskEncodedFrameFn` and the whole of `slopdesk-ffi/src/encoder.rs`
   were deleted, with `pub mod encoder;` from `lib.rs` and the `---- The HEVC encoder ----` block
   from `slopdesk_ffi.h`. The header's third-convention paragraph was not merely deleted: the
   CAPTURE stream's own callback door had said "the callback convention is the encoder's above,
   term for term", so that paragraph now states the convention itself.
5. `slopdesk-loopback-validate` followed the driver rather than keeping a copy. Its whole claim is
   that it measures the object the host actually drives.

`slopdesk-apple-vt`'s ratcheted spend is therefore THREE raw sites, one per framework area plus the
plane pair, listed per crate in `SAMPLE_MEMORY` in `rust/slopdesk-invariants/src/rules/crate_policy.rs`.
`docs/57` §2 carries the argument; a fourth site fails the ratchet, and so does an entry naming a
crate that no longer exists.

## §3 What the Rust daemon owed before the commit could be written — PAID

Ported: the argv grammar, the settings overlay, `--list`, the UDP mux and its lane registry, the
encoder's lifetime and its four encode paths, the whole WINDOW FEED — the census (`windowsource`),
the budgeted accessibility probe (`windowprobe`), the four placement sequences (`windowplace`), the
drag/union poll cadence (`windowgeometry`) and the feed loop over them (`feed`) — and, in this
commit, the capture stream (`capture`), the paced send lane and its retransmit log (`sendlane`), the
packetize lane (`packetize`), the cursor channel (`cursor`), the host blank (`privacy`), the display
wake (`wake`), the virtual display and its recovery policy (`vdisplay`), the off-screen mint rescue
(`rescue`), the audio lane (`audio`), and the session itself — its state (`session_wiring`), its
composition and lifetime (`session`), its bring-up and teardown (`session_capture`), its inbound
path (`session_inbound`), its feedback fold and actuation (`session_actuate`), and its
encoded-frame pump (`session_pump`) — and, last, REMOTE INPUT (`injector`): the raise chain, the
scroll resampler's pump, the swipe-back translation and every event that reaches the window server.

The injector was the port's one genuine hole rather than a missing file. `raise_target_window`
existed as a trait method and a test recorder and nothing else, `slopdesk-apple-cgevent` was not
even a dependency of the daemon, and a ported host in that state could not accept a click. The
orchestration moved out of `slopdesk-ffi` whole — it was already safe Rust behind a C door — and
landed in the crate that installs it, which is what deleted the door.

`VideoSessionLogic` never needed porting: it was a FACE. `SLOPDESK_VIDEO_SESSION_*` and
`SlopDeskVideoSessionEffect` are C spellings of `slopdesk_video::session_state`, which has held the
real state machine all along — as `LiveCongestionController`, `FPSGovernor`, `LTRController`,
`QPController` and `RecoveryIDRPolicy` were faces over `congestion`, `fps_governor`, `ltr`,
`qp_control` and `recovery_idr`. The daemon composes them; it re-derives none of them.

Structural changes worth naming, because each deletes a whole class of bug rather than a file:

- **The encoded-frame queue is gone.** The Swift ran finished frames through a FIFO, a coalesced
  wakeup and a consumer task purely to undo the reordering an `actor` hop caused. `VideoToolbox`
  already calls back on a serial queue, so `EncodedFrameSink` runs on the framework's thread and the
  pump IS that call — one queue, one wakeup and one thread hop per frame removed from between the
  encoder and the wire. The INBOUND queue stays, for the one reason that survives: coalescing needs
  a motion run to pile up, and injecting inline would back-pressure the socket instead.
- **One pacing plan, not two.** `PacePlan::for_frame` is a single value because the Swift computed
  pacing separately in two drains and they had already drifted — the second could not see
  `keyframe` and floored a recovery IDR at the delta pace floor.
- **One generation, not five `===`.** `Live<Capture, Encode>` replaces the five-way identity guard
  every rebuild path wrote by hand, and the class of bug where a new path forgets one of the five.
- **One `Outgoing`.** `packetize.rs` had re-declared the rules crate's own `Outgoing` and
  `schedule_frame_raw`; both were deleted in favour of `slopdesk_video::recovery_routing`'s.

## §4 The spine, and the two new homes the port needed

The modules above are what a session IS. What actually runs them landed in the same commit:

- **`main.rs`** — the nine-step launch order, and nothing else. Each "before" carries the reason it
  is not the other way round; the file's own header is the authority, not this list.
- **`minter.rs`** — one hello into one running session. Every failure DEGRADES to in-place 1×
  capture; exactly two things refuse, a window that is gone and unrescuable, and a hello after
  `close()`.
- **`parking.rs`** — the accessibility and crash-journal half of parked windows, over
  `slopdesk_video::window_parking`'s pure ledger. The journal's serde rows pin the PREVIOUS
  release's spellings (`windowID`, `originalX/Y/Width/Height`, `schemaVersion`) so this daemon can
  recover the last one's crash, and launch hygiene deletes the journal FIRST so a restore that
  itself crashes cannot loop.
- **`discovery.rs`** — the answers that mint nothing, asked BEFORE the registry so a lane that only
  wanted the window list never starts a capture for the privilege.
- **`session_resize.rs`** — the resize ladder, both paths. The IN-PLACE one reconfigures the live
  `SCStream` and swaps a new encoder under it, saving the framework's ~120 ms spin-up — the resize
  freeze — and `HostGates::in_place_resize_enabled` (`SLOPDESK_INPLACE_RESIZE`, default **ON**
  since 2026-09-02) selects it through `takes_in_place`, composed with the capture's own shape by
  `capture_config::can_resize_in_place`. It shipped OFF because no unit test can show that a
  `ScreenCaptureKit` stream applied a new configuration or that the first buffer after it arrived
  at the new size — `synthetic-tests-prove-nothing-fires` — and flipped the day `just gui-video`
  grew the drag that shows exactly that (`docs/70` §2.7); so the branch shipped implemented and
  unit-tested but not live-verified, and the restart path serves every resize until an operator
  sets the key or a host run promotes the default. The door it needed is `session_pump`'s `EncoderSlot`: a
  `VTCompressionSession` cannot change dimensions and a `Capturer`'s event sink is fixed at
  construction, so the pump's encoder lives behind one lock that a resize swaps between frames,
  with a size guard armed BY that swap so a buffer from before the reconfigure never reaches an
  encoder opened for after it. The encoder goes in under `Live::replace_encode`, which does NOT
  bump the generation — the SET was not replaced, and a bump would tell the live pump it had been
  superseded and swallow the next real capture death. EVERY way the fast path declines — gate off,
  a per-window capture, a poller-owned union crop, a framework that refused the new configuration —
  falls through to the RESTART path below with a set that is still capturing, which is what the
  Swift's own fallback did and why correctness never rides on the fast one.
  The AUDIO LANE survives the restart rebuild: it is handed to the new capturer by
  `CaptureStream::hand_over`, which is the whole reason that door exists, because tag 6's sequence
  is monotone across capturer rebuilds and a client that late-drops on it would go silent for the
  rest of the session. Three more things survive with it — the client's latched audio wish, the
  user's stream settings, and the FPS governor, which is not re-minted because its ladder position
  is knowledge about the LINK and a resize does not change the link.
- **`session_geometry.rs`** — the COMPOSITION over `windowgeometry.rs` and `cursor.rs`, and the one
  module in the daemon that is nothing but wiring. Both watchers were written, unit-tested and
  constructed nowhere for the length of the port; this file starts them, holds a `Weak<Session>` in
  each pump so the session→watcher→sink chain stays acyclic, and turns their observations into the
  three effects the Swift spread across its actor: the geometry datagram on the wire, the injector
  and cursor bounds RE-ORIGIN, and the display-anchored capture's re-anchor. It also owns the
  DIALOG-EXPAND region loop — every verdict in it comes from `slopdesk_video::capture_region`, the
  contract is debounced 400 ms while the expand is not, and a lost rebuild walks
  `capture_recovery::capture_failure_action`'s union → plain-window → disconnect ladder, which had
  been a decision function with no caller.
- **`diag.rs`** — one `write_all` of one buffer to stderr, prefixed with the invoked basename so two
  daemons in one log are distinguishable.

Two things could not live in the daemon and got their own homes:

- **`slopdesk_video::window_parking`** — the park/unpark refcount, the retarget and the restore
  ledger. It is a DECISION, so it is not in the daemon: the Swift file's own doc said as much.
- **`slopdesk-apple-nsapp`** — `become_accessory`, `run`, `drain_main_queue`. Zero `unsafe`;
  `objc2-app-kit` generates all three calls safe behind a `MainThreadMarker`.
- **`slopdesk-apple-nsevent`** — `pointer_cocoa`, one class method and no decisions. Zero `unsafe`
  and, unlike the three above, no `MainThreadMarker` in the generated signature — which is the
  reason it is its own crate rather than a fourth call in `slopdesk-apple-cursor`: reading where
  the pointer is must be callable from the sampler's own thread, and everything `NSCursor` answers
  must not. `docs/57`'s ledger carries the full ruling.

### The divergences from the Swift, each one deliberate

None of these is an accident, and none should be "fixed" without reading why:

1. **`AppIconRequest` and `WindowPreviewRequest` are not answered.** No door exists:
   `slopdesk-apple-app` exposes no `NSRunningApplication.icon`, and `slopdesk-apple-sck` has no
   `SCScreenshotManager` surface at all. Both fall through to the registry's unbound-lane drop, and
   a test in `discovery.rs` pins that fall-through so the gap is visible the day a door lands.
2. **Nothing ticks the window feed on a workspace change.** The Swift's `WindowFeedKicker` debounced
   `NSWorkspace` and frontmost-app notifications at ~150 ms; `Discovery::kick()` is exposed for a
   future one, and until something calls it the feed falls back to renewal-driven rebuilds and the
   differ's own tick. A named LATENCY regression, not a correctness one.
3. **A display hello resolves the main display as "the one at the global origin"**
   (`cgdisplay::under(0,0)`), which is CG's own definition of it. The Swift additionally fell back
   to the first display `ScreenCaptureKit` reported when the two disagreed; that fallback is gone,
   because `SCShareableContent.displays` is deliberately private in the sck crate and a
   locked-screen `None` is the honest answer rather than a guessed display.
4. **The drain deadline `abort()`s where the Swift `_exit(0)`d**, so `launchd` records a crash and
   writes a report. That is the price of a `forbid(unsafe_code)` crate — `_exit` is a raw libc call
   — and it is the right price: the deadline thread races the drain thread, and two concurrent
   `exit()`s run the atexit handlers twice, which is undefined behaviour. An abort racing an exit is
   not. It only ever fires on a daemon that is already wedged.
5. ~~**The adaptive-`m` FEC ladder is unreachable, and so is small-frame duplication.**~~ ✅ **CLOSED
   2026-08-31, and it was never a divergence — it was a one-sided silent hazard.**

   What the row said, and it was true as far as it went: both need `m > 1`, nothing on the host
   resolved one, `Session::new` pinned `ReedSolomonFec::default()` at `m = 1`, and so the `m`
   ladder's step, its three tiers 5/6/7 and the small-frame duplicate keying off them were all
   unreachable. The audit that re-read it found the other half LIVE. Swift's
   `AdaptiveFECPolicy.MultiLoss.parityCount` resolves `SLOPDESK_FEC_M` from the client's own
   environment and `makeFECScheme()` hands the result to the session, so the CLIENT honoured a key
   the HOST ignored. `Pending::new` takes `parity_shards_per_group` from the receiver's configured
   scheme and never off the wire — by design, which is what the multi-loss note's **DEPLOY
   TOGETHER** warning is about — so a client with `SLOPDESK_FEC_M=3` mis-mapped the parity boundary
   of every frame an `m = 1` host sent and silently stopped repairing. Nothing failed to decode and
   nothing logged. That is not "a feature is off"; that is two ends disagreeing with both configs
   looking correct.

   **The fix, in one change, because the two halves make each other reachable.**
   `session::configured_fec` resolves `SLOPDESK_FEC_K` / `_FEC_M` through
   `adaptive_fec::multi_loss`'s own `resolve_group_size` / `resolve_parity_count` — the same two
   functions the client calls, so there is no second clamp and no second GF(2^8) cap to keep in
   agreement. Unset resolves to `(k 5, m 1)`, which IS `ReedSolomonFec::default`, so an untouched
   fleet is byte-identical and this needed no deploy step of its own. Resolving `m` then made the
   small-frame branch reachable in the same stroke, so it was ported in the same change:
   `session_wiring::should_dup_small_delta`, folded into the SAME `duplicate` verdict the keyframe
   gate feeds, because one frame earns one second copy or none.

   Two deliberate departures from the Swift, both recorded in `session_pump`'s header. Its inline
   arm tested `stateMachine.mediaFlowing` and its lane arm did not; `wire_frame` tests it twice for
   both arms before either is reached, so the asymmetry has nowhere to live. And the ladder rung is
   passed as `Option<u8>` — `None` when the parity ladder is not running — rather than compared
   against a sentinel: `PARITY_TIER_CLEAN` is a RUNG, so a not-running ladder sitting at
   `DEFAULT_TIER` would read as "stepped" and arm the gate on every small delta forever.

   **One real divergence surfaced by making the ladder reachable, and closed in the same pass: the
   SEED.** `Controllers::new` seeded `TierState::default()` — tier 0 — unconditionally, while the
   Swift seeded `parityTierNormal` (6) whenever adaptive `m` was on, for the reason its own comment
   gave. While the ladder was unreachable that difference could not be observed; the moment it can
   run, an unreported session stamps a tier from OUTSIDE the ladder's `{5, 6, 7}` set on every frame
   until the first feedback report, which is exactly what `adaptive_fec::wire_tier`'s pass-through
   is documented not to do. `Controllers::new` now takes the resolved switch and seeds
   `PARITY_TIER_NORMAL` under it. Two of the three consequences are nil and one is the point:
   `m_level_for_tier` maps tier 0 and tier 6 to the same level, so the ladder steps identically from
   either, and both are `!= PARITY_TIER_CLEAN`, so the small-delta gate arms either way. What
   changes is the PARITY COUNT of the pre-report frames, and it is not cosmetic —
   `packetizer.rs` calls `adaptive_fec::parity_count(fec_tier, m)` per frame and `reassembler.rs`
   calls it off the stamped tier, so under multi-loss the tier is what the ladder actuates through.
   Tier 0 falls through that table to the configured `m`; tier 6 is the baseline 3. Both ends read
   the same stamped tier through the same table, so there is no disagreement in either seed — the
   fix is that the frames before the first report now carry the ladder's baseline, which is what the
   ladder means by baseline. `session_inbound::adaptive_m_enabled` became `pub(crate)` over `&Overlay` for it, since
   `Session::new` must answer the question before there is a `Session` to ask.

## §5 The door surface the deletion took with it

A door is a rule spelled a second time in C. The Swift video host was the only caller of 248 of
them, so deleting the host deleted them — this is the half of the port that removes header surface
rather than adding it, and `slopdesk-gate ffi` proves both directions of it in one run: no exported
symbol the header does not declare, and no declaration the library does not export.

**Twenty-six modules die whole.** `abr`, `app`, `capture`, `capture_gates`, `capture_region`,
`cgdisplay`, `cgwindow`, `cursor_sampler`, `frame_rate`, `host_gates`, `host_policy`, `host_state`,
`injector`, `input_routing`, `mint_rescue`, `mux_host`, `nav_history`, `power`, `recovery_idr`,
`send_pacing`, `session_state`, `swipe_nav_config`, `virtual_display`, `window_feed_host`,
`window_list`, `window_placement`. Every one of them had a live Rust module behind it already; what
died is the C spelling in between.

**Three Swift settings faces die with them**, and they are the reason four of those modules looked
alive to the gate: `HostGateTable`, `CaptureGateTable` and `InjectorGateTable` under
`Sources/SlopDeskVideoProtocol/Settings/`. Each resolved a HOST operating point through the shim,
and nothing but the other two referenced any of them. The daemon resolves the same keys from
`crate::env::Overlay` directly.

**Six modules shrink to what a client still opens.** `audio_codec` keeps the decoder and loses the
encoder — every client decodes, only the host encoded. `ax` keeps only the Accessibility TRUST
read, which is a question about the calling process and so belongs to the client that installs an
event tap. `rate_control` keeps only `slopdesk_qp_config_default`, because the settings sidecar has
to show the number each `SLOPDESK_QP_*` parse falls back to. `input_event`, `recovery` and
`video_policy` each lose the one or two host-only arms of an otherwise client-facing module.

**One shared type moved rather than died.** `SlopDeskByteSpan` lived in `host_state`, but two
surviving doors speak it — the pane session's paths and the folder store's — and neither
vocabulary can own the other's, so it sits in `lib.rs` beside the arena helpers that produce it.

**One door died for a different reason.** `slopdesk_input_box_event` had a Swift caller, but that
caller was `InputBoxModel.onEvent`, a sink nothing outside a test ever bound — the cross-language
mirror fixture the one-implementation rule bans. The events it published had already moved the
model, which is what a view actually reads, and `TerminalModeTracker::consume` remains the one way
to ask for the events themselves. With the sink gone the door had no caller, and
`slopdesk_input_box_ingest` answers a plain `size_t` instead of a two-field record whose second
field nobody could read.

**Four dead typedefs went with the last pass.** `SlopDeskIdrPolicy`, `SlopDeskIdrConfig`,
`SlopDeskQpController` and the five `SLOPDESK_IDR_VERDICT_*` constants outlived every door that
spoke them, because the gate compares SYMBOLS and a typedef exports none. A handle type for a handle
nothing mints is exactly the drift this section claims the commit removed, so the admission-laws
section is now the one struct a client still reads — `SlopDeskQpConfig`, and the default it falls
back to.

## §6 The one push the deletion broke, and where it lives now

`SwipeNavStatusGlue.swift` was not a face. It was the swipe-nav status kicker — the 4 Hz beat that
tells every client whether a swipe would translate right now (`docs/20` §9.6, cursor channel type
`3`) — and deleting the Swift daemon deleted the only producer of a wire message the client still
decodes. Nothing was red: the chip simply never lit again, which is the failure mode a deletion
ledger exists to catch.

It is two Rust modules now, split by who else wants them.

| module | what it holds |
| --- | --- |
| `rust/slopdesk-videohostd/src/navhistory.rs` | the accessibility JOIN: `slopdesk-apple-ax`'s walk under `slopdesk_video::nav_history`'s rules, with the cached pair |
| `rust/slopdesk-videohostd/src/navstatus.rs` | the CADENCE: the thread, the 250 ms beat, the forced-every-eighth heartbeat, the change key, and the fan-out |

Three things changed shape in the move, and each is a fact rather than a preference.

**The reader never leaves its thread.** Its cached pair holds live `AXUIElement`s, which are Core
Foundation objects and therefore neither `Send` nor `Sync`. The Swift held them in an
`@unchecked Sendable` class; this crate is `forbid(unsafe_code)` and may not write the equivalent,
so the reader is constructed inside the beat loop and shared with nothing. It wanted no second
caller anyway — the cache exists to make the NEXT beat cheap, and there is one beat.

**`NavHistoryFlags` stopped being a second struct.** `slopdesk_video::swipe_nav_config` declared its
own copy of `nav_history::Flags` for as long as the reader was Swift, because the two ends of a C
door cannot share a type. With the reader in Rust the copy was a translation the daemon would pay
for on every beat, so the name is a re-export now and there is one declaration.

**The operating point is resolved once.** `navstatus::operating_point` is the single overlay read of
the `SLOPDESK_SWIPE_NAV*` family, and `injector::resolve` asks it rather than repeating the parse —
which is the invariant `swipe-nav-handle` exists for, now true by construction rather than by
inspection.

What did NOT come back is the instant push on `NSWorkspace.didActivateApplicationNotification`:
nothing in the `slopdesk-apple-*` family carries workspace notifications, and which crate would own
them is a `docs/57` §2 question. An activation lands on the next CHANGE beat instead, so the chip is
at most one 250 ms beat late rather than never.

**`rust/slopdesk-navprobe` follows the reader.** It drove `slopdesk_ffi::nav_history` and carried a
note saying it would not compile until that reader had a safe constructor — a note whose premise was
already false, because `just lint` clippies every workspace crate. It links
`slopdesk-videohostd`'s `navhistory` now, which is the same reader the beat drives rather than a
copy of it, and it takes its forced-beat interval from `navstatus::FORCED_EVERY` so a probe run and
a live session force on the same beat.
